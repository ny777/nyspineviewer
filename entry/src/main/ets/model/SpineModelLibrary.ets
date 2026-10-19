/**
 * 模型库管理（移植 Android 版 SpineModelLoader.kt 导入流程）：
 * ZIP 选取 URI → 沙箱解压 → 递归扫描骨架 → 同目录 basename 去重（优先 .skel）
 * → 最小依赖收集（骨架 + 匹配 atlas + atlas 引用贴图 + 同名 config + 备选骨架）
 * → 版本嗅探 → files/models/<uuid>/ 落盘 + model_meta.json + library.json 索引。
 */
import { fileIo } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { Context } from '@kit.AbilityKit';
import { SpineModelItem } from './SpineModelItem';
import { detectSpineVersion } from '../core/SpineVersionDetector';
import { spineVersionToString } from '../core/SpineVersion';
import { Live2DConfig, parseLive2DConfig } from './Live2DConfig';

const TAG = 'SpineModelLibrary';

/** library.json 条目原始结构（JSON.parse 单次断言归一用）。 */
interface ModelItemRaw {
  id?: Object;
  name?: Object;
  folderPath?: Object;
  skelFile?: Object;
  atlasFile?: Object;
  animations?: Array<Object>;
  skins?: Array<Object>;
  version?: Object;
  format?: Object;
  createdAt?: Object;
  group?: Object;
}

/** model_meta.json 结构。 */
interface ModelMeta {
  id: string;
  name: string;
  version: string;
  format: string;
  skelFile: string;
  atlasFile: string;
  group: string;
}

/** 骨架 JSON 原始结构（动画/皮肤名嗅探用）。 */
interface SkeletonPeekRaw {
  animations?: Record<string, Object>;
  skins?: Record<string, Object>;
}

/** 模型库单例。 */
export class SpineModelLibrary {
  private static instance: SpineModelLibrary | null = null;
  private readonly filesDir: string;
  private readonly cacheDir: string;
  private readonly modelsRoot: string;
  private readonly libraryFile: string;
  private models: Array<SpineModelItem> = new Array<SpineModelItem>();

  private constructor(context: Context) {
    this.filesDir = context.filesDir;
    this.cacheDir = context.cacheDir;
    this.modelsRoot = `${this.filesDir}/models`;
    this.libraryFile = `${this.filesDir}/library.json`;
    if (!fileIo.accessSync(this.modelsRoot, fileIo.AccessModeType.EXIST)) {
      fileIo.mkdirSync(this.modelsRoot, true);
    }
  }

  static getInstance(context: Context): SpineModelLibrary {
    if (SpineModelLibrary.instance === null) {
      SpineModelLibrary.instance = new SpineModelLibrary(context);
    }
    return SpineModelLibrary.instance;
  }

  /** 读取 library.json 索引（过滤目录已缺失的条目）。 */
  async loadModels(): Promise<Array<SpineModelItem>> {
    const loaded = this.readLibraryIndex();
    const alive = new Array<SpineModelItem>();
    let dropped = false;
    for (const item of loaded) {
      if (fileIo.accessSync(item.folderPath, fileIo.AccessModeType.EXIST)) {
        alive.push(item);
      } else {
        dropped = true;
      }
    }
    this.models = alive;
    if (dropped) {
      this.writeLibraryIndex(this.models);
    }
    return this.getModels();
  }

  /** 缓存的模型列表（浅拷贝数组，元素为同一实例）。 */
  getModels(): Array<SpineModelItem> {
    const copy = new Array<SpineModelItem>();
    for (const m of this.models) {
      copy.push(m);
    }
    return copy;
  }

  getModelById(modelId: string): SpineModelItem | null {
    for (const m of this.models) {
      if (m.id === modelId) {
        return m;
      }
    }
    return null;
  }

  /**
   * 读取模型目录下 config（Live2DViewerEX 风格，对齐 Android 加载侧规则：
   * 目录内第一个以 .config.json 结尾的文件，大小写不敏感）。
   * 不存在或解析失败返回 null（调用方按「无 config」处理）。
   */
  readModelConfig(model: SpineModelItem): Live2DConfig | null {
    try {
      const names = fileIo.listFileSync(model.folderPath);
      for (const name of names) {
        if (name.toLowerCase().endsWith('.config.json')) {
          return parseLive2DConfig(fileIo.readTextSync(`${model.folderPath}/${name}`));
        }
      }
    } catch (err) {
      return null;
    }
    return null;
  }

  /**
   * 从选取的 ZIP URI 导入一个或多个模型（一个 ZIP 可含多角色）。
   * 失败抛 Error（message 为可读中文），staging 一定被清理。
   */
  async importZip(zipUri: string, group: string): Promise<Array<SpineModelItem>> {
    const uuid = util.generateRandomUUID(false);
    const stagingDir = `${this.cacheDir}/zip_staging_${uuid}`;
    const zipTmpPath = `${this.cacheDir}/import_${uuid}.zip`;
    fileIo.mkdirSync(stagingDir);

    let extractedCount = 0;
    try {
      const srcFile = fileIo.openSync(zipUri, fileIo.OpenMode.READ_ONLY);
      try {
        await fileIo.copyFile(srcFile.fd, zipTmpPath);
      } finally {
        fileIo.closeSync(srcFile);
      }
      await zlib.decompressFile(zipTmpPath, stagingDir);
      extractedCount = collectFilesRecursive(stagingDir).length;
    } catch (err) {
      this.cleanupTemp(stagingDir, zipTmpPath);
      throw new Error(`无法解压所选 ZIP 文件，请确认选择的是有效的 Spine 2D ZIP 压缩包：${JSON.stringify(err)}`);
    }

    if (extractedCount === 0) {
      this.cleanupTemp(stagingDir, zipTmpPath);
      throw new Error('无法从所选 ZIP 文件解压内容，请确认选择的是有效的 Spine 2D ZIP 压缩包');
    }

    // 收集骨架候选文件
    const allFiles = collectFilesRecursive(stagingDir);
    const skelFiles = new Array<string>();
    for (const file of allFiles) {
      if (isSkelCandidate(file)) {
        skelFiles.push(file);
      }
    }
    if (skelFiles.length === 0) {
      this.cleanupTemp(stagingDir, zipTmpPath);
      throw new Error('压缩包内未找到 Spine .skel / .json 骨骼数据文件');
    }

    // 同目录同 basename 视为同一模型，去重后仅导入一次（优先 .skel 二进制）
    const uniqueSkelFiles = dedupeSkelFiles(skelFiles);

    const imported = new Array<SpineModelItem>();
    for (const skelFullPath of uniqueSkelFiles) {
      const item = await this.importOneModel(skelFullPath, stagingDir, group);
      if (item !== null) {
        imported.push(item);
      }
    }

    this.cleanupTemp(stagingDir, zipTmpPath);

    if (imported.length === 0) {
      throw new Error('模型导入失败：未能从压缩包中提取出有效的 Spine 模型');
    }

    // 合并进索引：新模型置于列表头
    const incomingIds = new Set<string>();
    for (const item of imported) {
      incomingIds.add(item.id);
    }
    const merged = new Array<SpineModelItem>();
    for (const item of imported) {
      merged.push(item);
    }
    for (const existing of this.models) {
      if (!incomingIds.has(existing.id)) {
        merged.push(existing);
      }
    }
    this.models = merged;
    this.writeLibraryIndex(this.models);
    return imported;
  }

  /** 导入单个模型（一个骨架 + 最小依赖集）。失败返回 null。 */
  private async importOneModel(skelFullPath: string, stagingDir: string, group: string): Promise<SpineModelItem | null> {
    try {
      const skelName = baseName(skelFullPath);
      const modelRoot = parentDir(skelFullPath);
      const modelId = util.generateRandomUUID(false);
      const targetDir = `${this.modelsRoot}/${modelId}`;
      fileIo.mkdirSync(targetDir, true);

      // 模型显示名：骨架 basename；目录级通用名时回退为所在子目录名
      let rawName = stripSkelSuffix(skelName);
      const rawLower = rawName.toLowerCase();
      if (rawLower === 'skeleton' || rawLower === 'spine' || rawLower === 'data') {
        if (modelRoot !== stagingDir) {
          const dirName = baseName(modelRoot);
          if (dirName.length > 0) {
            rawName = dirName;
          }
        }
      }
      const modelName = rawName.length > 0 ? rawName : 'Spine Model';
      const base = stripSkelSuffix(skelName);

      const dirFiles = listDirFiles(modelRoot);

      // 复制骨架文件（平铺到模型目录根）
      await fileIo.copyFile(skelFullPath, `${targetDir}/${skelName}`);
      const finalSkelPath = `${targetDir}/${skelName}`;

      // 匹配 atlas：同 basename 优先，否则目录内唯一 atlas
      let atlasName = '';
      const matchedAtlas = findMatchedAtlas(dirFiles, base);
      if (matchedAtlas !== null) {
        atlasName = matchedAtlas;
        await fileIo.copyFile(`${modelRoot}/${matchedAtlas}`, `${targetDir}/${matchedAtlas}`);
      }

      // 收集 atlas 引用的贴图并复制（平铺）
      if (atlasName.length > 0) {
        const usedImages = resolveAtlasImages(`${targetDir}/${atlasName}`);
        const copiedNames = new Set<string>();
        for (const img of usedImages) {
          const src = findImageSource(dirFiles, img);
          if (src !== null && !copiedNames.has(src)) {
            copiedNames.add(src);
            try {
              await fileIo.copyFile(`${modelRoot}/${src}`, `${targetDir}/${src}`);
            } catch (err) {
              console.error(`${TAG} copy image ${src} failed: ${JSON.stringify(err)}`);
            }
          }
        }
        // 解析不到贴图时回退复制同前缀贴图
        if (copiedNames.size === 0) {
          for (const name of dirFiles) {
            if (startsWithIgnoreCase(name, base) && isImageFile(name) && !copiedNames.has(name)) {
              copiedNames.add(name);
              try {
                await fileIo.copyFile(`${modelRoot}/${name}`, `${targetDir}/${name}`);
              } catch (err) {
                console.error(`${TAG} copy fallback image ${name} failed: ${JSON.stringify(err)}`);
              }
            }
          }
        }
      } else {
        // 无 atlas（少见）：仅复制同前缀贴图
        for (const name of dirFiles) {
          if (startsWithIgnoreCase(name, base) && isImageFile(name)) {
            try {
              await fileIo.copyFile(`${modelRoot}/${name}`, `${targetDir}/${name}`);
            } catch (err) {
              console.error(`${TAG} copy prefix image ${name} failed: ${JSON.stringify(err)}`);
            }
          }
        }
      }

      // 复制同名 .config.json（可选，提供 scale/动画偏好）
      const configName = `${base}.config.json`;
      for (const name of dirFiles) {
        if (name === configName) {
          try {
            await fileIo.copyFile(`${modelRoot}/${name}`, `${targetDir}/${name}`);
          } catch (err) {
            console.error(`${TAG} copy config failed: ${JSON.stringify(err)}`);
          }
          break;
        }
      }

      // 复制备选骨架（同前缀 .skel.bytes/.json，体积小，便于回退）
      for (const name of dirFiles) {
        const lower = name.toLowerCase();
        if (name !== skelName && stripSkelSuffix(name) === base &&
          (lower.endsWith('.skel.bytes') || lower.endsWith('.json'))) {
          try {
            await fileIo.copyFile(`${modelRoot}/${name}`, `${targetDir}/${name}`);
          } catch (err) {
            console.error(`${TAG} copy alt skeleton failed: ${JSON.stringify(err)}`);
          }
          break;
        }
      }

      // 版本嗅探
      const detected = detectSpineVersion(finalSkelPath);
      const versionStr = spineVersionToString(detected.version);
      const formatStr = detected.format;

      // 动画/皮肤名：JSON 直接读取；二进制用占位（加载后由 onModelLoaded 回填）
      let animations = new Array<string>();
      let skins = new Array<string>();
      if (formatStr === 'JSON') {
        const peeked = peekAnimationsAndSkins(finalSkelPath);
        animations = peeked.animations;
        skins = peeked.skins;
      }
      if (animations.length === 0) {
        animations.push('idle');
      }
      if (skins.length === 0) {
        skins.push('default');
      }

      // 写 model_meta.json
      const meta: ModelMeta = {
        id: modelId,
        name: modelName,
        version: versionStr,
        format: formatStr,
        skelFile: skelName,
        atlasFile: atlasName,
        group: group
      };
      try {
        writeTextFile(`${targetDir}/model_meta.json`, JSON.stringify(meta));
      } catch (err) {
        console.error(`${TAG} write meta failed: ${JSON.stringify(err)}`);
      }

      return new SpineModelItem(modelId, modelName, targetDir, skelName, atlasName,
        animations, skins, versionStr, formatStr, Date.now(), group);
    } catch (err) {
      console.error(`${TAG} importOneModel failed: ${JSON.stringify(err)}`);
      return null;
    }
  }

  /** 删除模型（目录 + 索引）。 */
  async deleteModel(modelId: string): Promise<void> {
    const target = this.getModelById(modelId);
    if (target === null) {
      return;
    }
    deleteDirRecursive(target.folderPath);
    const remaining = new Array<SpineModelItem>();
    for (const m of this.models) {
      if (m.id !== modelId) {
        remaining.push(m);
      }
    }
    this.models = remaining;
    this.writeLibraryIndex(this.models);
  }

  /** 现有分组名列表（非空 group，按首现顺序）。 */
  getGroupNames(): Array<string> {
    const names = new Array<string>();
    for (const m of this.models) {
      if (m.group.length > 0 && !names.includes(m.group)) {
        names.push(m.group);
      }
    }
    return names;
  }

  /** 将单个模型移入分组（group 为 '' 表示未分组）。 */
  async setModelGroup(modelId: string, group: string): Promise<void> {
    const target = this.getModelById(modelId);
    if (target === null || target.group === group) {
      return;
    }
    target.group = group;
    this.rewriteMeta(target);
    this.writeLibraryIndex(this.models);
  }

  /** 解散分组：组内全部模型移入未分组（保留模型）。 */
  async dissolveGroup(group: string): Promise<void> {
    if (group.length === 0) {
      return;
    }
    let changed = false;
    for (const m of this.models) {
      if (m.group === group) {
        m.group = '';
        this.rewriteMeta(m);
        changed = true;
      }
    }
    if (changed) {
      this.writeLibraryIndex(this.models);
    }
  }

  /**
   * 删除分组。
   * @param group 分组名（非空）。
   * @param deleteModels true = 连同组内全部模型一起删除；false = 模型移入未分组。
   * @returns 被删除的模型 id 列表（deleteModels=false 时为空）。
   */
  async deleteGroup(group: string, deleteModels: boolean): Promise<Array<string>> {
    const deletedIds = new Array<string>();
    if (deleteModels) {
      const members = new Array<SpineModelItem>();
      for (const m of this.models) {
        if (m.group === group) {
          members.push(m);
        }
      }
      for (const m of members) {
        await this.deleteModel(m.id);
        deletedIds.push(m.id);
      }
    } else {
      await this.dissolveGroup(group);
    }
    return deletedIds;
  }

  /** 用条目当前字段重写 model_meta.json（分组变更持久化）。 */
  private rewriteMeta(item: SpineModelItem): void {
    try {
      const meta: ModelMeta = {
        id: item.id,
        name: item.name,
        version: item.version,
        format: item.format,
        skelFile: item.skelFile,
        atlasFile: item.atlasFile,
        group: item.group
      };
      writeTextFile(`${item.folderPath}/model_meta.json`, JSON.stringify(meta));
    } catch (err) {
      console.error(`${TAG} rewriteMeta failed: ${JSON.stringify(err)}`);
    }
  }

  /** 用渲染层真实加载结果回填动画/皮肤名（占位值不覆盖已有真实值）。 */
  updateModelAnimSkins(modelId: string, animations: Array<string>, skins: Array<string>): boolean {
    const target = this.getModelById(modelId);
    if (target === null || animations.length === 0 || skins.length === 0) {
      return false;
    }
    const newAnims = isPlaceholder(animations, 'idle') && target.animations.length > 1
      ? target.animations : animations;
    const newSkins = isPlaceholder(skins, 'default') && target.skins.length > 1
      ? target.skins : skins;
    if (arraysEqual(newAnims, target.animations) && arraysEqual(newSkins, target.skins)) {
      return false;
    }
    target.animations = newAnims;
    target.skins = newSkins;
    this.writeLibraryIndex(this.models);
    return true;
  }

  /** 清理临时目录与 ZIP。 */
  private cleanupTemp(stagingDir: string, zipTmpPath: string): void {
    try {
      deleteDirRecursive(stagingDir);
    } catch (err) {
      console.error(`${TAG} cleanup staging failed: ${JSON.stringify(err)}`);
    }
    try {
      if (fileIo.accessSync(zipTmpPath, fileIo.AccessModeType.EXIST)) {
        fileIo.unlinkSync(zipTmpPath);
      }
    } catch (err) {
      console.error(`${TAG} cleanup zip failed: ${JSON.stringify(err)}`);
    }
  }

  /** 读取 library.json。损坏时返回空列表（自愈为空库）。 */
  private readLibraryIndex(): Array<SpineModelItem> {
    if (!fileIo.accessSync(this.libraryFile, fileIo.AccessModeType.EXIST)) {
      return new Array<SpineModelItem>();
    }
    try {
      const text = fileIo.readTextSync(this.libraryFile);
      const rawItems = JSON.parse(text) as Array<ModelItemRaw>;
      if (!Array.isArray(rawItems)) {
        return new Array<SpineModelItem>();
      }
      const result = new Array<SpineModelItem>();
      for (const raw of rawItems) {
        if (typeof raw.id !== 'string' || typeof raw.name !== 'string' ||
          typeof raw.folderPath !== 'string' || typeof raw.skelFile !== 'string') {
          continue;
        }
        const animations = toStringList(raw.animations);
        const skins = toStringList(raw.skins);
        let atlasFile = '';
        if (typeof raw.atlasFile === 'string') {
          atlasFile = raw.atlasFile;
        }
        let version = 'unknown';
        if (typeof raw.version === 'string' && raw.version.length > 0) {
          version = raw.version;
        }
        let format = 'SKEL';
        if (typeof raw.format === 'string' && raw.format.length > 0) {
          format = raw.format;
        }
        let createdAt = Date.now();
        if (typeof raw.createdAt === 'number' && Number.isFinite(raw.createdAt)) {
          createdAt = raw.createdAt;
        }
        let group = '';
        if (typeof raw.group === 'string') {
          group = raw.group;
        }
        result.push(new SpineModelItem(raw.id, raw.name, raw.folderPath, raw.skelFile,
          atlasFile, animations, skins, version, format, createdAt, group));
      }
      return result;
    } catch (err) {
      console.error(`${TAG} readLibraryIndex failed: ${JSON.stringify(err)}`);
      return new Array<SpineModelItem>();
    }
  }

  /** 写 library.json 索引。 */
  private writeLibraryIndex(models: Array<SpineModelItem>): void {
    try {
      const rawItems = new Array<ModelItemRaw>();
      for (const m of models) {
        const raw: ModelItemRaw = {
          id: m.id,
          name: m.name,
          folderPath: m.folderPath,
          skelFile: m.skelFile,
          atlasFile: m.atlasFile,
          animations: toObjectList(m.animations),
          skins: toObjectList(m.skins),
          version: m.version,
          format: m.format,
          createdAt: m.createdAt,
          group: m.group
        };
        rawItems.push(raw);
      }
      writeTextFile(this.libraryFile, JSON.stringify(rawItems));
    } catch (err) {
      console.error(`${TAG} writeLibraryIndex failed: ${JSON.stringify(err)}`);
    }
  }
}

// ==================== 文件系统辅助（模块级具名函数） ====================

/** 递归收集目录下全部文件（绝对路径）。 */
function collectFilesRecursive(rootDir: string): Array<string> {
  const result = new Array<string>();
  if (!fileIo.accessSync(rootDir, fileIo.AccessModeType.EXIST)) {
    return result;
  }
  const relativePaths = fileIo.listFileSync(rootDir, { recursion: true });
  for (const rel of relativePaths) {
    const full = `${rootDir}/${rel.startsWith('/') ? rel.substring(1) : rel}`;
    try {
      const stat = fileIo.statSync(full);
      if (stat.isFile()) {
        result.push(full);
      }
    } catch (err) {
      // 单个条目 stat 失败跳过（可能是被锁定的临时文件）
    }
  }
  return result;
}

/** 非递归列出目录内文件名（仅文件，不含子目录）。 */
function listDirFiles(dirPath: string): Array<string> {
  const names = new Array<string>();
  if (!fileIo.accessSync(dirPath, fileIo.AccessModeType.EXIST)) {
    return names;
  }
  const entries = fileIo.listFileSync(dirPath);
  for (const entry of entries) {
    try {
      const stat = fileIo.statSync(`${dirPath}/${entry}`);
      if (stat.isFile()) {
        names.push(entry);
      }
    } catch (err) {
      // 跳过
    }
  }
  return names;
}

/** 递归删除目录（文件 + 子目录 + 自身）。 */
function deleteDirRecursive(dirPath: string): void {
  if (!fileIo.accessSync(dirPath, fileIo.AccessModeType.EXIST)) {
    return;
  }
  const entries = fileIo.listFileSync(dirPath);
  for (const entry of entries) {
    const full = `${dirPath}/${entry}`;
    try {
      const stat = fileIo.statSync(full);
      if (stat.isDirectory()) {
        deleteDirRecursive(full);
      } else {
        fileIo.unlinkSync(full);
      }
    } catch (err) {
      console.error(`${TAG} delete entry ${entry} failed: ${JSON.stringify(err)}`);
    }
  }
  fileIo.rmdirSync(dirPath);
}

/** 路径最后一段。 */
function baseName(path: string): string {
  const idx = path.lastIndexOf('/');
  if (idx < 0) {
    return path;
  }
  return path.substring(idx + 1);
}

/** 去掉最后一段的父目录路径（无 '/' 返回空串）。 */
function parentDir(path: string): string {
  const idx = path.lastIndexOf('/');
  if (idx <= 0) {
    return '';
  }
  return path.substring(0, idx);
}

/** 去掉扩展名。 */
function stripExtension(fileName: string): string {
  const idx = fileName.lastIndexOf('.');
  if (idx <= 0) {
    return fileName;
  }
  return fileName.substring(0, idx);
}

/** 去掉骨架后缀（.skel/.skel.bytes/.json），得到模型 basename。 */
function stripSkelSuffix(fileName: string): string {
  let name = stripExtension(fileName);
  const lower = name.toLowerCase();
  if (lower.endsWith('.skel')) {
    name = name.substring(0, name.length - '.skel'.length);
  } else if (lower.endsWith('.json')) {
    name = name.substring(0, name.length - '.json'.length);
  }
  return name;
}

function isImageFile(name: string): boolean {
  const n = name.toLowerCase();
  return n.endsWith('.png') || n.endsWith('.jpg') || n.endsWith('.jpeg') || n.endsWith('.webp');
}

function startsWithIgnoreCase(name: string, prefix: string): boolean {
  if (prefix.length === 0) {
    return false;
  }
  return name.toLowerCase().startsWith(prefix.toLowerCase());
}

/** 骨架候选判定（对齐 Android 版规则）。 */
function isSkelCandidate(fullPath: string): boolean {
  const lower = fullPath.toLowerCase();
  if (lower.endsWith('.skel') || lower.endsWith('.skel.bytes')) {
    return true;
  }
  if (lower.endsWith('.json') && !lower.endsWith('.config.json') &&
    !lower.endsWith('build.json') && !lower.endsWith('model_meta.json')) {
    try {
      const text = fileIo.readTextSync(fullPath);
      return text.includes('bones') || text.includes('skeleton') || text.includes('animations');
    } catch (err) {
      return false;
    }
  }
  return false;
}

/** 同目录同 basename 去重（优先 .skel/.skel.bytes）。 */
function dedupeSkelFiles(skelFiles: Array<string>): Array<string> {
  const groups = new Map<string, Array<string>>();
  for (const file of skelFiles) {
    const key = `${parentDir(file)}::${stripSkelSuffix(baseName(file)).toLowerCase()}`;
    const group = groups.get(key);
    if (group === undefined) {
      const fresh = new Array<string>();
      fresh.push(file);
      groups.set(key, fresh);
    } else {
      group.push(file);
    }
  }
  const result = new Array<string>();
  groups.forEach((group: Array<string>) => {
    let chosen: string | null = null;
    for (const file of group) {
      const lower = baseName(file).toLowerCase();
      if (lower.endsWith('.skel') || lower.endsWith('.skel.bytes')) {
        chosen = file;
        break;
      }
    }
    if (chosen === null) {
      chosen = group[0];
    }
    result.push(chosen);
  });
  return result;
}

/** 查找匹配的 atlas 文件名：同 basename 优先，否则目录内首个 atlas。 */
function findMatchedAtlas(dirFiles: Array<string>, base: string): string | null {
  let fallback: string | null = null;
  for (const name of dirFiles) {
    const lower = name.toLowerCase();
    const isAtlas = lower.endsWith('.atlas') || lower.endsWith('.atlas.txt');
    if (!isAtlas) {
      continue;
    }
    if (stripExtension(lower) === base.toLowerCase() || stripExtension(stripExtension(lower)) === base.toLowerCase()) {
      return name;
    }
    if (fallback === null) {
      fallback = name;
    }
  }
  return fallback;
}

/**
 * 解析 atlas 文本中所有 page 引用的贴图文件名。
 * 规则：无冒号的 token 行，其下一个非空行以 "size:" 开头 → 该 token 是贴图行。
 */
function resolveAtlasImages(atlasPath: string): Array<string> {
  const result = new Array<string>();
  try {
    const text = fileIo.readTextSync(atlasPath);
    const lines = text.split('\n');
    let i = 0;
    while (i < lines.length) {
      let trimmed = lines[i].trim();
      if (trimmed.startsWith('\uFEFF')) {
        trimmed = trimmed.substring(1);
      }
      if (trimmed.length > 0 && !trimmed.includes(':')) {
        let j = i + 1;
        while (j < lines.length && lines[j].trim().length === 0) {
          j++;
        }
        const nextProp = j < lines.length ? lines[j].trim() : '';
        if (nextProp.startsWith('size:')) {
          const clean = trimmed.replace(/\\/g, '/');
          const idx = clean.lastIndexOf('/');
          const filePart = idx >= 0 ? clean.substring(idx + 1) : clean;
          if (filePart.length > 0 && !result.includes(filePart)) {
            result.push(filePart);
          }
          i = j;
        }
      }
      i++;
    }
  } catch (err) {
    console.error(`${TAG} resolveAtlasImages failed: ${JSON.stringify(err)}`);
  }
  return result;
}

/** 在目录文件列表中查找贴图源（精确名 / 大小写不敏感 / 仅 basename）。 */
function findImageSource(dirFiles: Array<string>, imageName: string): string | null {
  const lowerTarget = imageName.toLowerCase();
  const baseTarget = baseName(imageName).toLowerCase();
  for (const name of dirFiles) {
    if (name === imageName) {
      return name;
    }
  }
  for (const name of dirFiles) {
    if (name.toLowerCase() === lowerTarget) {
      return name;
    }
  }
  for (const name of dirFiles) {
    if (baseName(name).toLowerCase() === baseTarget) {
      return name;
    }
  }
  return null;
}

/** JSON 骨架动画/皮肤名嗅探（快路径）。 */
function peekAnimationsAndSkins(skelJsonPath: string): PeekResult {
  const result = new PeekResult();
  try {
    const text = fileIo.readTextSync(skelJsonPath);
    const raw = JSON.parse(text) as SkeletonPeekRaw;
    if (raw.animations !== undefined && raw.animations !== null) {
      const keys = Object.keys(raw.animations);
      for (const key of keys) {
        if (key.length > 0) {
          result.animations.push(key);
        }
      }
    }
    if (raw.skins !== undefined && raw.skins !== null) {
      const keys = Object.keys(raw.skins);
      for (const key of keys) {
        if (key.length > 0) {
          result.skins.push(key);
        }
      }
    }
  } catch (err) {
    console.error(`${TAG} peekAnimationsAndSkins failed: ${JSON.stringify(err)}`);
  }
  return result;
}

/** 嗅探结果载体。 */
class PeekResult {
  animations: Array<string> = new Array<string>();
  skins: Array<string> = new Array<string>();
}

function isPlaceholder(list: Array<string>, placeholder: string): boolean {
  return list.length === 1 && list[0] === placeholder;
}

function arraysEqual(a: Array<string>, b: Array<string>): boolean {
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      return false;
    }
  }
  return true;
}

function toStringList(raw: Array<Object> | undefined): Array<string> {
  const result = new Array<string>();
  if (raw === undefined || raw === null) {
    return result;
  }
  for (const item of raw) {
    if (typeof item === 'string') {
      result.push(item);
    }
  }
  return result;
}

function toObjectList(list: Array<string>): Array<Object> {
  const result = new Array<Object>();
  for (const item of list) {
    const obj: Object = item;
    result.push(obj);
  }
  return result;
}

/** 全量写入文本文件（CREATE + TRUNC）。 */
function writeTextFile(filePath: string, text: string): void {
  const file = fileIo.openSync(filePath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE |
    fileIo.OpenMode.TRUNC);
  try {
    fileIo.writeSync(file.fd, text);
  } finally {
    fileIo.closeSync(file);
  }
}
