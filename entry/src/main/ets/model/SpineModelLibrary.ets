/**
 * 模型库管理（移植 Android 版 SpineModelLoader.kt 导入流程）：
 * ZIP 选取 URI → 沙箱解压 → 递归扫描骨架 → 同目录 basename 去重（优先 .skel）
 * → 最小依赖收集（骨架 + 匹配 atlas + atlas 引用贴图 + 同名 config + 备选骨架）
 * → 版本嗅探 → files/models/<uuid>/ 落盘 + model_meta.json + library.json 索引。
 */
import { fileIo } from '@kit.CoreFileKit';
import { zlib, BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { Context } from '@kit.AbilityKit';
import { SpineModelItem } from './SpineModelItem';
import { detectFormat, detectSpineVersionFromText } from '../core/SpineVersionDetector';
import { spineVersionToString } from '../core/SpineVersion';
import { peekSkelBinaryFile } from '../core/SpineBinaryPeeker';
import { Live2DConfig, parseLive2DConfig } from './Live2DConfig';

const TAG = 'SpineModelLibrary';
/** 哈希流式读取块大小（256KB）。 */
const HASH_CHUNK_BYTES = 262144;

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
  contentHash?: Object;
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

/** trash.json 条目原始结构（JSON.parse 单次断言归一用）。 */
interface TrashItemRaw {
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
  contentHash?: Object;
  deletedAt?: Object;
}

/** 回收站条目（模型 + 删除时间戳）。 */
export class TrashEntry {
  model: SpineModelItem;
  deletedAt: number;

  constructor(model: SpineModelItem, deletedAt: number) {
    this.model = model;
    this.deletedAt = deletedAt;
  }
}

/** 骨架 JSON 原始结构（动画/皮肤名嗅探用）。 */
interface SkeletonPeekRaw {
  animations?: Record<string, Object>;
  skins?: Record<string, Object>;
}

/** 批量导入结果汇总。 */
export class BatchImportResult {
  importedCount: number = 0;
  /** 本批成功导入的模型 id（缩略图自动生成等后续处理用）。 */
  importedIds: Array<string> = new Array<string>();
  firstImportedId: string = '';
  failedZips: Array<string> = new Array<string>();
  /** 内容哈希判重跳过的模型数。 */
  skippedDuplicates: number = 0;
  /** 用户中途取消。 */
  cancelled: boolean = false;
}

/** 单 ZIP 解压暂存导入结果（importStaged 产物）。 */
class StagedImportResult {
  imported: Array<SpineModelItem> = new Array<SpineModelItem>();
  duplicates: number = 0;
}

/** 单模型导入结果状态（importOneModel 产物）。 */
class ImportOneOutcome {
  /** imported | duplicate | failed */
  status: string = 'failed';
  item: SpineModelItem | null = null;
}

/** ZIP 解压暂存（stageZip 产物，供 importStaged 消费）。 */
class ZipStage {
  stagingDir: string = '';
  zipTmpPath: string = '';
  skelFiles: Array<string> = new Array<string>();
}

/** 模型库单例。 */
export class SpineModelLibrary {
  private static instance: SpineModelLibrary | null = null;
  private readonly filesDir: string;
  private readonly cacheDir: string;
  private readonly modelsRoot: string;
  private readonly libraryFile: string;
  private readonly trashRoot: string;
  private readonly trashFile: string;
  private models: Array<SpineModelItem> = new Array<SpineModelItem>();

  private constructor(context: Context) {
    this.filesDir = context.filesDir;
    this.cacheDir = context.cacheDir;
    this.modelsRoot = `${this.filesDir}/models`;
    this.libraryFile = `${this.filesDir}/library.json`;
    this.trashRoot = `${this.filesDir}/trash`;
    this.trashFile = `${this.filesDir}/trash.json`;
    if (!fileIo.accessSync(this.modelsRoot, fileIo.AccessModeType.EXIST)) {
      fileIo.mkdirSync(this.modelsRoot, true);
    }
    if (!fileIo.accessSync(this.trashRoot, fileIo.AccessModeType.EXIST)) {
      fileIo.mkdirSync(this.trashRoot, true);
    }
  }

  static getInstance(context: Context): SpineModelLibrary {
    if (SpineModelLibrary.instance === null) {
      SpineModelLibrary.instance = new SpineModelLibrary(context);
    }
    return SpineModelLibrary.instance;
  }

  /** 读取 library.json 索引（过滤目录已缺失的条目）。目录存在性用一次 listFileSync 建集校验，避免逐条 stat。 */
  async loadModels(): Promise<Array<SpineModelItem>> {
    const loaded = this.readLibraryIndex();
    const existingDirs = new Set<string>();
    try {
      const names: Array<string> = fileIo.listFileSync(this.modelsRoot);
      for (let i = 0; i < names.length; i++) {
        existingDirs.add(names[i]);
      }
    } catch (err) {
      // models 目录不可列时按全部缺失处理（下方逐条剔除）
    }
    const alive = new Array<SpineModelItem>();
    let dropped = false;
    for (const item of loaded) {
      if (existingDirs.has(item.id)) {
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
   * 批量导入多个 ZIP：单模型 ZIP 归入 fallbackGroup；含 ≥2 个模型的 ZIP
   * 自动以 ZIP 显示名建组。单 ZIP 失败仅记录，不中断整批。
   * 内容哈希判重：与库内既有模型或本批已导入模型重复时跳过并计数。
   * shouldCancel 返回 true 时在当前 ZIP 边界中止（已完成结果保留）。
   */
  async importBatch(zipUris: Array<string>, fallbackGroup: string,
    onProgress: (done: number, total: number) => void,
    shouldCancel?: () => boolean): Promise<BatchImportResult> {
    const result = new BatchImportResult();
    const seenHashes = new Set<string>();
    for (const m of this.models) {
      if (m.contentHash.length > 0) {
        seenHashes.add(m.contentHash);
      }
    }
    const total = zipUris.length;
    let indexDirty = false;
    try {
      for (let i = 0; i < total; i++) {
        if (shouldCancel !== undefined && shouldCancel()) {
          result.cancelled = true;
          break;
        }
        const uri = zipUris[i];
        let stage: ZipStage | null = null;
        try {
          stage = await this.stageZip(uri);
          const group = stage.skelFiles.length >= 2 ? zipDisplayName(uri) : fallbackGroup;
          const staged = await this.importStaged(stage, group, seenHashes);
          if (staged.imported.length > 0) {
            indexDirty = true;
          }
          result.importedCount += staged.imported.length;
          for (const item of staged.imported) {
            result.importedIds.push(item.id);
          }
          result.skippedDuplicates += staged.duplicates;
          if (result.firstImportedId === '' && staged.imported.length > 0) {
            result.firstImportedId = staged.imported[0].id;
          }
        } catch (err) {
          console.error(`${TAG} importBatch zip failed: ${JSON.stringify(err)}`);
          result.failedZips.push(zipDisplayName(uri));
        } finally {
          if (stage !== null) {
            this.cleanupTemp(stage.stagingDir, stage.zipTmpPath);
          }
        }
        onProgress(i + 1, total);
      }
    } finally {
      // library.json 整批只写一次（中途取消/异常也保证已导入部分落盘）
      if (indexDirty) {
        this.writeLibraryIndex(this.models);
      }
    }
    return result;
  }

  /**
   * ZIP 解压暂存：复制 → 解压 → 收集骨架 → 同目录 basename 去重。
   * 失败抛 Error（message 为可读中文），失败路径自行清理临时产物。
   */
  private async stageZip(zipUri: string): Promise<ZipStage> {
    const uuid = util.generateRandomUUID(false);
    const stage = new ZipStage();
    stage.stagingDir = `${this.cacheDir}/zip_staging_${uuid}`;
    stage.zipTmpPath = `${this.cacheDir}/import_${uuid}.zip`;
    fileIo.mkdirSync(stage.stagingDir);

    try {
      const srcFile = fileIo.openSync(zipUri, fileIo.OpenMode.READ_ONLY);
      try {
        await fileIo.copyFile(srcFile.fd, stage.zipTmpPath);
      } finally {
        fileIo.closeSync(srcFile);
      }
      await zlib.decompressFile(stage.zipTmpPath, stage.stagingDir);
    } catch (err) {
      this.cleanupTemp(stage.stagingDir, stage.zipTmpPath);
      throw new Error(`无法解压所选 ZIP 文件，请确认选择的是有效的 Spine 2D ZIP 压缩包：${JSON.stringify(err)}`);
    }

    // 解压树单次递归扫描，后续（骨架收集/贴图校验）全部复用
    const allFiles = collectFilesRecursive(stage.stagingDir);
    if (allFiles.length === 0) {
      this.cleanupTemp(stage.stagingDir, stage.zipTmpPath);
      throw new Error('无法从所选 ZIP 文件解压内容，请确认选择的是有效的 Spine 2D ZIP 压缩包');
    }

    // 收集骨架候选文件
    const skelFiles = new Array<string>();
    for (const file of allFiles) {
      if (isSkelCandidate(file)) {
        skelFiles.push(file);
      }
    }
    if (skelFiles.length === 0) {
      this.cleanupTemp(stage.stagingDir, stage.zipTmpPath);
      throw new Error('压缩包内未找到 Spine .skel / .json 骨骼数据文件');
    }

    // 同目录同 basename 视为同一模型，去重后仅导入一次（优先 .skel 二进制）
    stage.skelFiles = dedupeSkelFiles(skelFiles);

    // 导入时贴图存在性校验：atlas 引用的页在暂存树中完全无匹配即失败（提前拦截渲染期黑屏）
    try {
      this.validateStagedTextures(stage, allFiles);
    } catch (err) {
      this.cleanupTemp(stage.stagingDir, stage.zipTmpPath);
      throw err as Error;
    }
    return stage;
  }

  /**
   * 校验暂存产物内每个骨架的 atlas 页引用均能在暂存树中找到贴图文件
   * （basename + 小写 + 去扩展名宽松匹配，与 AtlasSanitizer 归一规则一致；
   * 大小写/反斜杠差异放行，加载时由 sanitize 修正）。缺失抛 Error。
   * allFiles 为 stageZip 单次扫描出的暂存树全量文件列表。
   */
  private validateStagedTextures(stage: ZipStage, allFiles: Array<string>): void {
    const fileIndex: Record<string, boolean> = {};
    for (const file of allFiles) {
      const name = baseName(file).toLowerCase();
      fileIndex[name] = true;
      const dot = name.lastIndexOf('.');
      if (dot > 0) {
        fileIndex[name.substring(0, dot)] = true;
      }
    }
    for (const skelFullPath of stage.skelFiles) {
      const dirFiles = listDirFiles(parentDir(skelFullPath));
      const base = stripSkelSuffix(baseName(skelFullPath));
      const matchedAtlas = findMatchedAtlas(dirFiles, base);
      if (matchedAtlas === null) {
        continue;
      }
      const pages = resolveAtlasImages(`${parentDir(skelFullPath)}/${matchedAtlas}`);
      for (const page of pages) {
        if (fileIndex[page.toLowerCase()] !== true) {
          throw new Error(`贴图缺失: ${page}（请确认压缩包内包含完整贴图文件）`);
        }
      }
    }
  }

  /**
   * 导入暂存产物（一个 ZIP 可含多角色），合并进索引：新模型置于列表头。
   * 全部失败且无重复时抛 Error；临时产物由调用方（importBatch finally）清理。
   */
  private async importStaged(stage: ZipStage, group: string,
    seenHashes: Set<string>): Promise<StagedImportResult> {
    const result = new StagedImportResult();
    for (const skelFullPath of stage.skelFiles) {
      const outcome = await this.importOneModel(skelFullPath, stage.stagingDir, group, seenHashes);
      if (outcome.status === 'imported' && outcome.item !== null) {
        result.imported.push(outcome.item);
      } else if (outcome.status === 'duplicate') {
        result.duplicates++;
      }
    }

    if (result.imported.length === 0 && result.duplicates === 0) {
      throw new Error('模型导入失败：未能从压缩包中提取出有效的 Spine 模型');
    }

    if (result.imported.length > 0) {
      const incomingIds = new Set<string>();
      for (const item of result.imported) {
        incomingIds.add(item.id);
      }
      const merged = new Array<SpineModelItem>();
      for (const item of result.imported) {
        merged.push(item);
      }
      for (const existing of this.models) {
        if (!incomingIds.has(existing.id)) {
          merged.push(existing);
        }
      }
      this.models = merged;
      // library.json 不在此逐 ZIP 写盘，由 importBatch 收尾统一写一次
    }
    return result;
  }

  /**
   * 导入单个模型（一个骨架 + 最小依赖集）。失败返回 failed，重复返回 duplicate。
   * 内容哈希在复制前基于暂存文件计算（与目标副本字节一致），命中重复直接跳过全部复制；
   * 依赖集复制并行执行（Promise.all），贴图/config/备选骨架失败仅记录不中断。
   */
  private async importOneModel(skelFullPath: string, stagingDir: string, group: string,
    seenHashes: Set<string>): Promise<ImportOneOutcome> {
    const outcome = new ImportOneOutcome();
    try {
      const skelName = baseName(skelFullPath);
      const modelRoot = parentDir(skelFullPath);
      const dirFiles = listDirFiles(modelRoot);
      const base = stripSkelSuffix(skelName);

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

      // 匹配 atlas：同 basename 优先，否则目录内唯一 atlas
      const matchedAtlas = findMatchedAtlas(dirFiles, base);
      const atlasName = matchedAtlas !== null ? matchedAtlas : '';

      // 内容哈希判重（skel + atlas 字节 SHA-256，复制前基于暂存路径计算）：命中即弃，未命中登记
      const contentHash = await computeContentHash(skelFullPath,
        atlasName.length > 0 ? `${modelRoot}/${atlasName}` : '');
      if (contentHash.length > 0) {
        if (seenHashes.has(contentHash)) {
          outcome.status = 'duplicate';
          return outcome;
        }
        seenHashes.add(contentHash);
      }

      // 版本嗅探（JSON 文本只读一次，动画/皮肤嗅探复用同一文本）
      const formatStr = detectFormat(skelFullPath);
      let jsonText = '';
      if (formatStr === 'JSON') {
        jsonText = fileIo.readTextSync(skelFullPath);
      }
      const detected = detectSpineVersionFromText(skelFullPath, jsonText);
      const versionStr = spineVersionToString(detected.version);

      // 动画/皮肤名：JSON 直接读取；二进制 4.0/4.1/4.2 离线预解析（失败回退占位，加载后回填兜底）；
      // 3.8 二进制不做离线预解析，走占位 + 播放后回填（web 端解析真实名回报）
      let animations = new Array<string>();
      let skins = new Array<string>();
      if (formatStr === 'JSON') {
        const peeked = peekAnimationsAndSkinsFromText(jsonText);
        animations = peeked.animations;
        skins = peeked.skins;
      } else if (versionStr === '4.0' || versionStr === '4.1' || versionStr === '4.2') {
        const peeked = peekSkelBinaryFile(skelFullPath, versionStr);
        if (peeked !== null) {
          animations = peeked.animations;
          skins = peeked.skins;
        }
      }
      if (animations.length === 0) {
        animations.push('idle');
      }
      if (skins.length === 0) {
        skins.push('default');
      }

      // 目标目录 + 依赖集并行复制
      const modelId = util.generateRandomUUID(false);
      const targetDir = `${this.modelsRoot}/${modelId}`;
      fileIo.mkdirSync(targetDir, true);
      const copies = new Array<Promise<void>>();

      // 复制骨架文件（平铺到模型目录根）
      copies.push(fileIo.copyFile(skelFullPath, `${targetDir}/${skelName}`));

      // 复制 atlas 与其引用贴图（平铺）
      if (atlasName.length > 0) {
        copies.push(fileIo.copyFile(`${modelRoot}/${atlasName}`, `${targetDir}/${atlasName}`));
        const usedImages = resolveAtlasImages(`${modelRoot}/${atlasName}`);
        const copiedNames = new Set<string>();
        for (const img of usedImages) {
          const src = findImageSource(dirFiles, img);
          if (src !== null && !copiedNames.has(src)) {
            copiedNames.add(src);
            const imgSrc = src;
            copies.push(fileIo.copyFile(`${modelRoot}/${src}`, `${targetDir}/${src}`)
              .catch((err: BusinessError): void => {
                console.error(`${TAG} copy image ${imgSrc} failed: ${JSON.stringify(err)}`);
              }));
          }
        }
        // 解析不到贴图时回退复制同前缀贴图
        if (copiedNames.size === 0) {
          for (const name of dirFiles) {
            if (startsWithIgnoreCase(name, base) && isImageFile(name) && !copiedNames.has(name)) {
              copiedNames.add(name);
              const fbName = name;
              copies.push(fileIo.copyFile(`${modelRoot}/${name}`, `${targetDir}/${name}`)
                .catch((err: BusinessError): void => {
                  console.error(`${TAG} copy fallback image ${fbName} failed: ${JSON.stringify(err)}`);
                }));
            }
          }
        }
      } else {
        // 无 atlas（少见）：仅复制同前缀贴图
        for (const name of dirFiles) {
          if (startsWithIgnoreCase(name, base) && isImageFile(name)) {
            const pxName = name;
            copies.push(fileIo.copyFile(`${modelRoot}/${name}`, `${targetDir}/${name}`)
              .catch((err: BusinessError): void => {
                console.error(`${TAG} copy prefix image ${pxName} failed: ${JSON.stringify(err)}`);
              }));
          }
        }
      }

      // 复制同名 .config.json（可选，提供 scale/动画偏好）
      const configName = `${base}.config.json`;
      for (const name of dirFiles) {
        if (name === configName) {
          copies.push(fileIo.copyFile(`${modelRoot}/${name}`, `${targetDir}/${name}`)
            .catch((err: BusinessError): void => {
              console.error(`${TAG} copy config failed: ${JSON.stringify(err)}`);
            }));
          break;
        }
      }

      // 复制备选骨架（同前缀 .skel.bytes/.json，体积小，便于回退）
      for (const name of dirFiles) {
        const lower = name.toLowerCase();
        if (name !== skelName && stripSkelSuffix(name) === base &&
          (lower.endsWith('.skel.bytes') || lower.endsWith('.json'))) {
          const altName = name;
          copies.push(fileIo.copyFile(`${modelRoot}/${name}`, `${targetDir}/${name}`)
            .catch((err: BusinessError): void => {
              console.error(`${TAG} copy alt skeleton failed: ${JSON.stringify(err)}`);
            }));
          break;
        }
      }
      await Promise.all(copies);

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

      const item = new SpineModelItem(modelId, modelName, targetDir, skelName, atlasName,
        animations, skins, versionStr, formatStr, Date.now(), group, contentHash);
      outcome.status = 'imported';
      outcome.item = item;
      return outcome;
    } catch (err) {
      console.error(`${TAG} importOneModel failed: ${JSON.stringify(err)}`);
      return outcome;
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

  // ==================== 回收站 ====================

  /** 读取 trash.json 索引（目录已缺失的条目丢弃并自愈重写）。 */
  private readTrashIndex(): Array<TrashEntry> {
    const result = new Array<TrashEntry>();
    if (!fileIo.accessSync(this.trashFile, fileIo.AccessModeType.EXIST)) {
      return result;
    }
    try {
      const text = fileIo.readTextSync(this.trashFile);
      const rawItems = JSON.parse(text) as Array<TrashItemRaw>;
      if (!Array.isArray(rawItems)) {
        return new Array<TrashEntry>();
      }
      let dropped = false;
      // 一次 listFileSync 建集校验回收站目录存在性，避免逐条 stat
      const existingDirs = new Set<string>();
      try {
        const names: Array<string> = fileIo.listFileSync(this.trashRoot);
        for (let i = 0; i < names.length; i++) {
          existingDirs.add(names[i]);
        }
      } catch (err) {
        // trash 目录不可列时按全部缺失处理
      }
      for (const raw of rawItems) {
        if (typeof raw.id !== 'string' || typeof raw.name !== 'string' ||
          typeof raw.folderPath !== 'string' || typeof raw.skelFile !== 'string' ||
          typeof raw.deletedAt !== 'number' || !Number.isFinite(raw.deletedAt)) {
          continue;
        }
        const lastSlash = raw.folderPath.lastIndexOf('/');
        const folderName = lastSlash >= 0 ? raw.folderPath.substring(lastSlash + 1) : raw.folderPath;
        if (!existingDirs.has(folderName)) {
          dropped = true;
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
        let createdAt = raw.deletedAt;
        if (typeof raw.createdAt === 'number' && Number.isFinite(raw.createdAt)) {
          createdAt = raw.createdAt;
        }
        let group = '';
        if (typeof raw.group === 'string') {
          group = raw.group;
        }
        let contentHash = '';
        if (typeof raw.contentHash === 'string') {
          contentHash = raw.contentHash;
        }
        const model = new SpineModelItem(raw.id, raw.name, raw.folderPath, raw.skelFile,
          atlasFile, animations, skins, version, format, createdAt, group, contentHash);
        result.push(new TrashEntry(model, raw.deletedAt));
      }
      if (dropped) {
        this.writeTrashIndex(result);
      }
      return result;
    } catch (err) {
      console.error(`${TAG} readTrashIndex failed: ${JSON.stringify(err)}`);
      return new Array<TrashEntry>();
    }
  }

  /** 写 trash.json 索引。 */
  private writeTrashIndex(entries: Array<TrashEntry>): void {
    try {
      const rawItems = new Array<TrashItemRaw>();
      for (const entry of entries) {
        const m = entry.model;
        const raw: TrashItemRaw = {
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
          group: m.group,
          contentHash: m.contentHash,
          deletedAt: entry.deletedAt
        };
        rawItems.push(raw);
      }
      writeTextFile(this.trashFile, JSON.stringify(rawItems));
    } catch (err) {
      console.error(`${TAG} writeTrashIndex failed: ${JSON.stringify(err)}`);
    }
  }

  /** 将单个模型移入回收站：目录搬移到 trash/<id>，双写索引；缩略图保留。 */
  async moveToTrash(modelId: string): Promise<void> {
    const target = this.getModelById(modelId);
    if (target === null) {
      return;
    }
    const trashedPath = `${this.trashRoot}/${modelId}`;
    fileIo.renameSync(target.folderPath, trashedPath);
    const remaining = new Array<SpineModelItem>();
    for (const m of this.models) {
      if (m.id !== modelId) {
        remaining.push(m);
      }
    }
    this.models = remaining;
    target.folderPath = trashedPath;
    this.writeLibraryIndex(this.models);
    const entries = this.readTrashIndex();
    entries.push(new TrashEntry(target, Date.now()));
    this.writeTrashIndex(entries);
  }

  /** 批量移入回收站：串行搬移，单个失败继续下一个，不中断整批。 */
  async moveModelsToTrash(ids: Array<string>): Promise<void> {
    for (const id of ids) {
      try {
        await this.moveToTrash(id);
      } catch (err) {
        console.error(`${TAG} moveToTrash ${id} failed: ${JSON.stringify(err)}`);
      }
    }
  }

  /** 回收站条目列表（按删除时间降序）。 */
  getTrashedModels(): Array<TrashEntry> {
    const entries = this.readTrashIndex();
    entries.sort((a: TrashEntry, b: TrashEntry): number => b.deletedAt - a.deletedAt);
    return entries;
  }

  /** 从回收站恢复模型：目录搬回 models/<id>，重新插入库列表头部。未找到返回 false。 */
  async restoreFromTrash(modelId: string): Promise<boolean> {
    const entries = this.readTrashIndex();
    let target: TrashEntry | null = null;
    for (const entry of entries) {
      if (entry.model.id === modelId) {
        target = entry;
        break;
      }
    }
    if (target === null) {
      return false;
    }
    const restoredPath = `${this.modelsRoot}/${modelId}`;
    fileIo.renameSync(target.model.folderPath, restoredPath);
    const remaining = new Array<TrashEntry>();
    for (const entry of entries) {
      if (entry.model.id !== modelId) {
        remaining.push(entry);
      }
    }
    this.writeTrashIndex(remaining);
    target.model.folderPath = restoredPath;
    const exists = this.models.some((m: SpineModelItem): boolean => m.id === modelId);
    if (!exists) {
      this.models = [target.model].concat(this.models);
      this.writeLibraryIndex(this.models);
    }
    return true;
  }

  /** 彻底删除回收站内单个模型（目录 + 索引条目；缩略图由调用方清理）。 */
  async purgeTrashEntry(modelId: string): Promise<void> {
    const entries = this.readTrashIndex();
    const remaining = new Array<TrashEntry>();
    let removedDir = '';
    for (const entry of entries) {
      if (entry.model.id === modelId) {
        removedDir = entry.model.folderPath;
      } else {
        remaining.push(entry);
      }
    }
    if (removedDir.length > 0) {
      deleteDirRecursive(removedDir);
      this.writeTrashIndex(remaining);
    }
  }

  /** 清空回收站：全部彻底删除（返回被清除的模型 id 列表，缩略图由调用方清理）。 */
  async emptyTrash(): Promise<Array<string>> {
    const entries = this.readTrashIndex();
    const purgedIds = new Array<string>();
    for (const entry of entries) {
      deleteDirRecursive(entry.model.folderPath);
      purgedIds.push(entry.model.id);
    }
    if (purgedIds.length > 0) {
      this.writeTrashIndex(new Array<TrashEntry>());
    }
    return purgedIds;
  }

  /**
   * 按保留策略清除过期条目（retentionDays <= 0 表示永久保留，直接返回）。
   * 返回被清除的模型 id 列表（缩略图由调用方清理）。
   */
  async purgeExpiredTrash(retentionDays: number): Promise<Array<string>> {
    if (retentionDays <= 0) {
      return new Array<string>();
    }
    const entries = this.readTrashIndex();
    const threshold = Date.now() - retentionDays * 86400000;
    const remaining = new Array<TrashEntry>();
    const purgedIds = new Array<string>();
    for (const entry of entries) {
      if (entry.deletedAt < threshold) {
        deleteDirRecursive(entry.model.folderPath);
        purgedIds.push(entry.model.id);
      } else {
        remaining.push(entry);
      }
    }
    if (purgedIds.length > 0) {
      this.writeTrashIndex(remaining);
    }
    return purgedIds;
  }

  // ==================== 模型重命名 ====================

  /** 重命名模型显示名（允许与其他模型重名；持久化 library.json + model_meta.json）。 */
  async renameModel(modelId: string, newName: string): Promise<boolean> {
    const trimmed = newName.trim();
    const target = this.getModelById(modelId);
    if (target === null || trimmed.length === 0 || trimmed === target.name) {
      return false;
    }
    target.name = trimmed;
    this.rewriteMeta(target);
    this.writeLibraryIndex(this.models);
    return true;
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

  /**
   * 重命名分组：目标名与既有分组冲突返回 false；成功时组内全部模型
   * 的 group 替换并持久化（library.json + model_meta.json）。
   */
  async renameGroup(oldName: string, newName: string): Promise<boolean> {
    const trimmed = newName.trim();
    if (oldName.length === 0 || trimmed.length === 0) {
      return false;
    }
    if (trimmed === oldName) {
      return true;
    }
    for (const m of this.models) {
      if (m.group === trimmed) {
        return false;
      }
    }
    let changed = false;
    for (const m of this.models) {
      if (m.group === oldName) {
        m.group = trimmed;
        this.rewriteMeta(m);
        changed = true;
      }
    }
    if (changed) {
      this.writeLibraryIndex(this.models);
    }
    return changed;
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
        let contentHash = '';
        if (typeof raw.contentHash === 'string') {
          contentHash = raw.contentHash;
        }
        result.push(new SpineModelItem(raw.id, raw.name, raw.folderPath, raw.skelFile,
          atlasFile, animations, skins, version, format, createdAt, group, contentHash));
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
          group: m.group,
          contentHash: m.contentHash
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

/** ZIP URI 的显示名：末段 → URL 解码 → 去 .zip → 截断 48 字符；空回退 'import'。 */
function zipDisplayName(uri: string): string {
  const idx = uri.lastIndexOf('/');
  let name = idx >= 0 ? uri.substring(idx + 1) : uri;
  try {
    name = decodeURIComponent(name);
  } catch (err) {
    // 解码失败保留原文
  }
  if (name.toLowerCase().endsWith('.zip')) {
    name = name.substring(0, name.length - '.zip'.length);
  }
  if (name.length > 48) {
    name = name.substring(0, 48);
  }
  if (name.trim().length === 0) {
    return 'import';
  }
  return name;
}

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

/** JSON 骨架动画/皮肤名嗅探（快路径，文本由调用方一次读出复用，避免二次读盘解析）。 */
function peekAnimationsAndSkinsFromText(jsonText: string): PeekResult {
  const result = new PeekResult();
  try {
    const raw = JSON.parse(jsonText) as SkeletonPeekRaw;
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
    console.error(`${TAG} peekAnimationsAndSkinsFromText failed: ${JSON.stringify(err)}`);
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

// ==================== 内容哈希（重复导入判重） ====================

/**
 * 计算 skel + atlas 字节流的 SHA-256 hex（atlas 为空串时仅 skel）。
 * 读取或摘要失败返回空串（调用方按未知哈希处理，不参与判重）。
 */
async function computeContentHash(skelPath: string, atlasPath: string): Promise<string> {
  try {
    const md = cryptoFramework.createMd('SHA256');
    await hashUpdateFile(md, skelPath);
    if (atlasPath.length > 0) {
      await hashUpdateFile(md, atlasPath);
    }
    const digest = await md.digest();
    return bytesToHex(digest.data);
  } catch (err) {
    console.error(`${TAG} computeContentHash failed: ${JSON.stringify(err)}`);
    return '';
  }
}

/** 流式读取文件并喂给摘要器（分块避免大 skel 一次性占内存）。 */
async function hashUpdateFile(md: cryptoFramework.Md, path: string): Promise<void> {
  const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
  try {
    const buf = new ArrayBuffer(HASH_CHUNK_BYTES);
    while (true) {
      const nread = fileIo.readSync(file.fd, buf);
      if (nread <= 0) {
        break;
      }
      const chunk = new Uint8Array(buf, 0, nread);
      await md.update({ data: chunk });
    }
  } finally {
    fileIo.closeSync(file);
  }
}

/** Uint8Array → 小写 hex 串。 */
function bytesToHex(bytes: Uint8Array): string {
  const HEX = '0123456789abcdef';
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    out += HEX.charAt((bytes[i] >> 4) & 0x0F);
    out += HEX.charAt(bytes[i] & 0x0F);
  }
  return out;
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
