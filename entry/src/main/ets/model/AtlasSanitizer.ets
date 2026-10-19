/**
 * Atlas 文件清理与尺寸校正（移植自 Android AtlasSanitizer.kt / AtlasImageResampler.kt）。
 *
 * 处理 AssetStudio 从 Unity 资源解包出的 Spine atlas 常见问题：
 *  1) 贴图文件名大小写、反斜杠、UTF-8 BOM 清理；
 *  2) atlas 声明的 size: 与贴图实际像素尺寸不一致（Unity 导入按 NPOT 规则整页非等比拉伸，
 *     如 1692x2020 -> 2048x2048）。spine-ts 的 TextureAtlas 用实际贴图尺寸归一化 UV，
 *     导致采样错位（「模型轮廓在、贴图全乱」）。修复方式：把贴图重采样回声明尺寸，
 *     bounds/offsets 全部不用改。
 *
 * ⚠️ 不要动 rotate: —— Spine 4.x 的 rotate: 90/180/270 默认行为即正确，
 *    补偿旋转反而会让原本正常的模型贴图异常。
 *
 * 产物缓存：
 *  - 清理后的 atlas：`_sanitized_v2_<atlas名>`（以 `_` 开头，加载逻辑会跳过 `_` 开头文件）；
 *  - 重采样的贴图：`_fixed_<贴图名>.png`。
 *  改动生成逻辑时把前缀版本号 +1，旧缓存因前缀不匹配自然失效。
 */

import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const CACHE_PREFIX = '_sanitized_v2_';
const FIXED_PREFIX = '_fixed_';
const LOG_DOMAIN = 0x0031;
const TAG = 'AtlasSanitizer';
/** 读图片头部的字节数（JPEG 的 SOF 段几乎总在前 64KB 内；超出则按无法判断跳过修复）。 */
const HEAD_BYTES = 65536;

/** 清理结果：atlasFile 为模型目录内应使用的 atlas 文件名。 */
export class SanitizeResult {
  atlasFile: string;
  fromCache: boolean;

  constructor(atlasFile: string, fromCache: boolean) {
    this.atlasFile = atlasFile;
    this.fromCache = fromCache;
  }
}

/** 图片像素尺寸。 */
class ImageSize {
  width: number;
  height: number;

  constructor(width: number, height: number) {
    this.width = width;
    this.height = height;
  }
}

/** atlas 页引用（记录页文件名所在行号与声明的 size:）。 */
class PageRef {
  nameLine: number;
  declared: Array<number> | null = null;

  constructor(nameLine: number) {
    this.nameLine = nameLine;
  }
}

/**
 * 清理并校正 atlas，返回应使用的 atlas 文件名（相对模型目录）。
 * 任何失败都返回原始文件名（调用方按未修复继续加载）。
 */
export async function sanitizeAtlas(atlasPath: string): Promise<SanitizeResult> {
  const slash = atlasPath.lastIndexOf('/');
  if (slash <= 0 || slash === atlasPath.length - 1) {
    return new SanitizeResult(atlasPath, false);
  }
  const parentDir = atlasPath.substring(0, slash);
  const atlasName = atlasPath.substring(slash + 1);
  try {
    // 上次生成的中间产物若仍有效则直接复用（免去重解析 + 重写盘）
    const cachedName = CACHE_PREFIX + atlasName;
    const cachedPath = `${parentDir}/${cachedName}`;
    if (isCacheUsable(cachedPath, atlasPath, parentDir)) {
      hilog.debug(LOG_DOMAIN, TAG, 'cache-hit %{public}s', cachedName);
      return new SanitizeResult(cachedName, true);
    }

    const lines = fileIo.readTextSync(atlasPath).split('\n');

    // 模型目录内顶层文件的「小写名 → 实际名」映射（含去扩展名键）
    const entries = fileIo.listFileSync(parentDir);
    const diskMap: Record<string, string> = {};
    for (const entry of entries) {
      try {
        if (!fileIo.statSync(`${parentDir}/${entry}`).isFile()) {
          continue;
        }
      } catch (err) {
        continue;
      }
      diskMap[entry.toLowerCase()] = entry;
      const dot = entry.lastIndexOf('.');
      if (dot > 0) {
        diskMap[entry.substring(0, dot).toLowerCase()] = entry;
      }
    }

    let modified = false;

    // ---------- 第 1 步：清理（BOM / 反斜杠 / 贴图文件名大小写） ----------
    for (let i = 0; i < lines.length; i++) {
      let line = lines[i];
      if (line.length > 0 && (line.charCodeAt(0) === 0xFEFF || line.charCodeAt(0) === 0xFFFE)) {
        line = line.substring(1);
        modified = true;
      }
      if (line.indexOf('\\') >= 0) {
        line = line.split('\\').join('/');
        modified = true;
      }
      const trimmed = line.trim();
      if (trimmed.length > 0 && trimmed.indexOf(':') < 0) {
        const cleanBase = trimmed.substring(trimmed.lastIndexOf('/') + 1);
        const key = cleanBase.toLowerCase();
        let matched = diskMap[key] ?? '';
        if (matched.length === 0) {
          let stripped = key;
          if (stripped.endsWith('.png') || stripped.endsWith('.jpg')) {
            stripped = stripped.substring(0, stripped.length - 4);
          } else if (stripped.endsWith('.jpeg')) {
            stripped = stripped.substring(0, stripped.length - 5);
          }
          matched = diskMap[stripped] ?? '';
        }
        if (matched.length > 0 && matched !== trimmed) {
          line = matched;
          modified = true;
        }
      }
      lines[i] = line;
    }

    // ---------- 第 2 步：解析页与声明尺寸（只记行号，便于精确改写） ----------
    const pages: Array<PageRef> = [];
    let page: PageRef | null = null;
    let inRegion = false;
    for (let i = 0; i < lines.length; i++) {
      const text = lines[i].trim();
      if (text.length === 0) {
        continue;
      }
      if (text.indexOf(':') < 0) {
        const lower = text.substring(text.lastIndexOf('/') + 1).toLowerCase();
        if (lower.endsWith('.png') || lower.endsWith('.jpg') ||
          lower.endsWith('.jpeg') || lower.endsWith('.webp')) {
          page = new PageRef(i);
          pages.push(page);
          inRegion = false;
        } else if (page !== null) {
          inRegion = true;
        }
        continue;
      }
      if (!inRegion) {
        const colon = text.indexOf(':');
        const key = text.substring(0, colon).trim().toLowerCase();
        if (key === 'size' && page !== null) {
          page.declared = parseInts(text.substring(colon + 1).trim());
        }
      }
    }

    // ---------- 第 3 步：贴图尺寸校正（重采样回声明尺寸） ----------
    for (const p of pages) {
      const declared = p.declared;
      if (declared === null || declared.length < 2 || declared[0] <= 0 || declared[1] <= 0) {
        continue;
      }
      const imageName = lines[p.nameLine].trim();
      const imagePath = `${parentDir}/${imageName}`;
      const imageSize = readImageSize(imagePath);
      if (imageSize === null) {
        continue;
      }
      if (declared[0] === imageSize.width && declared[1] === imageSize.height) {
        continue;
      }
      const fixed = await resampleImage(imagePath, declared[0], declared[1]);
      if (fixed.length > 0) {
        lines[p.nameLine] = fixed;
        modified = true;
      }
    }

    if (modified) {
      writeTextFile(cachedPath, lines.join('\n'));
      hilog.info(LOG_DOMAIN, TAG, 'sanitized %{public}s -> %{public}s', atlasName, cachedName);
      return new SanitizeResult(cachedName, false);
    }
    return new SanitizeResult(atlasName, false);
  } catch (err) {
    hilog.warn(LOG_DOMAIN, TAG, 'sanitize failed, fallback to raw atlas: %{public}s', atlasName);
    return new SanitizeResult(atlasName, false);
  }
}

/** 中间产物是否可直接复用：不比源 atlas 旧，且引用的每个贴图都还在。 */
function isCacheUsable(cachedPath: string, sourcePath: string, parentDir: string): boolean {
  try {
    if (!fileIo.accessSync(cachedPath)) {
      return false;
    }
    if (fileIo.statSync(cachedPath).mtime < fileIo.statSync(sourcePath).mtime) {
      return false;
    }
    const lines = fileIo.readTextSync(cachedPath).split('\n');
    let anyPage = false;
    for (const rawLine of lines) {
      const text = rawLine.trim();
      if (text.length === 0 || text.indexOf(':') >= 0) {
        continue;
      }
      const lower = text.substring(text.lastIndexOf('/') + 1).toLowerCase();
      if (lower.endsWith('.png') || lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') || lower.endsWith('.webp')) {
        anyPage = true;
        if (!fileIo.accessSync(`${parentDir}/${text}`)) {
          return false;
        }
      }
    }
    return anyPage;
  } catch (err) {
    return false;
  }
}

/** 读 PNG / JPEG 头里的宽高（只读文件头部，不解码整图）；其他格式返回 null。 */
function readImageSize(path: string): ImageSize | null {
  let file: fileIo.File | null = null;
  try {
    file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    const buf = new ArrayBuffer(HEAD_BYTES);
    const nread = fileIo.readSync(file.fd, buf);
    if (nread < 2) {
      return null;
    }
    const u8 = new Uint8Array(buf, 0, nread);
    // PNG：8 字节签名，宽高在 IHDR 偏移 16 / 20
    if (nread >= 24 && u8[0] === 0x89 && u8[1] === 0x50 && u8[2] === 0x4E && u8[3] === 0x47) {
      return new ImageSize(beInt(u8, 16), beInt(u8, 20));
    }
    // JPEG：扫描 SOF 段
    if (u8[0] === 0xFF && u8[1] === 0xD8) {
      return readJpegSize(u8);
    }
    return null;
  } catch (err) {
    return null;
  } finally {
    if (file !== null) {
      try {
        fileIo.closeSync(file);
      } catch (err) {
        // 关闭失败不影响判定
      }
    }
  }
}

/** JPEG SOF 段解析：跳过填充 0xFF 与非 SOF 段，返回 [w, h]。 */
function readJpegSize(u8: Uint8Array): ImageSize | null {
  let i = 2;
  while (i < u8.length) {
    if (u8[i] !== 0xFF) {
      i++;
      continue;
    }
    while (i < u8.length && u8[i] === 0xFF) {
      i++;
    }
    if (i >= u8.length) {
      return null;
    }
    const marker = u8[i];
    i++;
    if (marker === 0x01 || (marker >= 0xD0 && marker <= 0xD8)) {
      continue;
    }
    if (i + 1 >= u8.length) {
      return null;
    }
    const segLen = (u8[i] << 8) | u8[i + 1];
    i += 2;
    if (segLen < 2) {
      return null;
    }
    // SOF0..SOF15，排除 DHT(0xC4) / JPG(0xC8) / DAC(0xCC)
    if (marker >= 0xC0 && marker <= 0xCF && marker !== 0xC4 && marker !== 0xC8 && marker !== 0xCC) {
      if (i + 4 >= u8.length) {
        return null;
      }
      const h = (u8[i + 1] << 8) | u8[i + 2];
      const w = (u8[i + 3] << 8) | u8[i + 4];
      return new ImageSize(w, h);
    }
    i += segLen - 2;
  }
  return null;
}

function beInt(u8: Uint8Array, off: number): number {
  return ((u8[off] << 24) | (u8[off + 1] << 16) | (u8[off + 2] << 8) | u8[off + 3]) >>> 0;
}

/** 解析 atlas 页头的 `size: w, h` 声明；非法返回 null。 */
function parseInts(value: string): Array<number> | null {
  const parts = value.split(',');
  if (parts.length < 2) {
    return null;
  }
  const out: Array<number> = [];
  for (const part of parts) {
    const n = parseInt(part.trim(), 10);
    if (Number.isNaN(n)) {
      return null;
    }
    out.push(n);
  }
  return out;
}

/**
 * 把被拉伸过的贴图重采样成 width x height 的 PNG（缓存为 `_fixed_<名>.png`）。
 * 失败返回空串（调用方跳过该页的尺寸修正）。
 */
async function resampleImage(sourcePath: string, width: number, height: number): Promise<string> {
  if (width <= 0 || height <= 0) {
    return '';
  }
  const slash = sourcePath.lastIndexOf('/');
  const parentDir = sourcePath.substring(0, slash);
  const name = sourcePath.substring(slash + 1);
  const dot = name.lastIndexOf('.');
  const fixedName = `${FIXED_PREFIX}${dot > 0 ? name.substring(0, dot) : name}.png`;
  const fixedPath = `${parentDir}/${fixedName}`;
  try {
    // 同尺寸缓存直接复用（重采样一张 2048² 要几十毫秒）
    if (fileIo.accessSync(fixedPath)) {
      const cachedSize = readImageSize(fixedPath);
      if (cachedSize !== null && cachedSize.width === width && cachedSize.height === height) {
        return fixedName;
      }
    }
    const source = image.createImageSource(sourcePath);
    try {
      const pm = await source.createPixelMap();
      try {
        const info = await pm.getImageInfo();
        if (info.size.width === width && info.size.height === height) {
          return '';
        }
        hilog.info(LOG_DOMAIN, TAG, 'resample %{public}s %{public}dx%{public}d -> %{public}dx%{public}d',
          name, info.size.width, info.size.height, width, height);
        await pm.scale(width / info.size.width, height / info.size.height);
        const packer = image.createImagePacker();
        try {
          const opts: image.PackingOption = { format: 'image/png', quality: 100 };
          const data = await packer.packToData(pm, opts);
          writeBinaryFile(fixedPath, data);
        } finally {
          packer.release();
        }
        return fixedName;
      } finally {
        pm.release();
      }
    } finally {
      source.release();
    }
  } catch (err) {
    hilog.warn(LOG_DOMAIN, TAG, 'resample failed: %{public}s', name);
    return '';
  }
}

/** 全量写入文本文件（CREATE + TRUNC，UTF-8）。 */
function writeTextFile(filePath: string, text: string): void {
  const file = fileIo.openSync(filePath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE |
    fileIo.OpenMode.TRUNC);
  try {
    fileIo.writeSync(file.fd, text);
  } finally {
    fileIo.closeSync(file);
  }
}

/** 全量写入二进制文件（CREATE + TRUNC）。 */
function writeBinaryFile(filePath: string, data: ArrayBuffer): void {
  const file = fileIo.openSync(filePath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE |
    fileIo.OpenMode.TRUNC);
  try {
    fileIo.writeSync(file.fd, data);
  } finally {
    fileIo.closeSync(file);
  }
}
