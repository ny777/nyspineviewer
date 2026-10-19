/**
 * Spine 版本嗅探器（逐行移植 Android 版 SpineVersionDetector.kt）。
 *
 * 二进制检测逻辑与官方 SkeletonBinary 读取方式一致：
 * - Spine 3.8 及更早：hash = readString()（字符串）→ version = readString()
 * - Spine 4.0+：hash = readLong()（8 字节整数）→ version = readString()
 * readString = varint 长度前缀(7bit 分组, MSB 标记续段) + UTF-8 字节，
 * byteCount==1 表示空串，读取 (byteCount-1) 字节。
 */
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import {
  SpineVersion,
  spineVersionFromString,
  spineVersionFromMajorMinor
} from './SpineVersion';

const TAG = 'SpineVersionDetector';
const MAX_HEADER_BYTES = 2048;

/** 嗅探结果。 */
export interface SpineDetectResult {
  version: SpineVersion;
  format: string;
}

/** 骨骼 JSON 的原始结构（仅用于 JSON.parse 归一化，字段均可缺省）。 */
interface SkeletonJsonRaw {
  skeleton?: SkeletonMetaRaw;
  spine?: string;
}

interface SkeletonMetaRaw {
  spine?: string;
}

/**
 * 检测骨骼文件（.skel 或 .json）的 Spine 版本与格式。
 * fileFullPath 为沙箱内绝对路径。
 */
export function detectSpineVersion(fileFullPath: string): SpineDetectResult {
  const format = detectFormat(fileFullPath);
  if (format === 'JSON') {
    return { version: detectFromJson(fileFullPath), format: format };
  }
  return { version: detectFromBinary(fileFullPath), format: format };
}

/** 按扩展名判断格式：JSON / SKEL。 */
export function detectFormat(fileFullPath: string): string {
  const normalized = fileFullPath.toLowerCase();
  if (normalized.endsWith('.json') || normalized.endsWith('.json.txt')) {
    return 'JSON';
  }
  return 'SKEL';
}

/** 解析 JSON 骨骼描述中的 skeleton.spine 版本字段。 */
function detectFromJson(fileFullPath: string): SpineVersion {
  try {
    const text = fileIo.readTextSync(fileFullPath);
    const parsed: object = JSON.parse(text);
    const raw = parsed as SkeletonJsonRaw;
    if (raw.skeleton !== undefined && raw.skeleton !== null &&
      typeof raw.skeleton.spine === 'string' && raw.skeleton.spine.length > 0) {
      return spineVersionFromString(raw.skeleton.spine);
    }
    if (typeof raw.spine === 'string' && raw.spine.length > 0) {
      return spineVersionFromString(raw.spine);
    }
    return SpineVersion.UNKNOWN;
  } catch (err) {
    console.error(`${TAG} detectFromJson failed: ${JSON.stringify(err)}`);
    return SpineVersion.UNKNOWN;
  }
}

/**
 * 二进制 .skel 头嗅探：
 * 1) 4.x 格式 [8 字节 long hash][varint string version]
 * 2) 3.8 及更早 [string hash][string version]
 * 3) 头部明文版本号正则兜底
 */
function detectFromBinary(fileFullPath: string): SpineVersion {
  let header: Uint8Array | null = null;
  try {
    header = readHeaderBytes(fileFullPath, MAX_HEADER_BYTES);
  } catch (err) {
    console.error(`${TAG} read header failed: ${JSON.stringify(err)}`);
    return SpineVersion.UNKNOWN;
  }
  if (header === null || header.length < 8) {
    return SpineVersion.UNKNOWN;
  }

  // 1. Spine 4.x 头：跳 8 字节 long hash + varint 字符串
  let cursor = 8;
  const v40 = tryReadVersionString(header, cursor);
  if (v40 !== null) {
    const ver = spineVersionFromString(v40.trim());
    if (ver !== SpineVersion.UNKNOWN) {
      return ver;
    }
  }

  // 2. Spine 3.8 头：字符串 hash + 字符串 version
  cursor = 0;
  const hash38 = tryReadSkelString(header, cursor);
  if (hash38 !== null) {
    // hash 消耗的字节数需重算：重新走一遍 varint
    const hashLen = skelStringLength(header, 0);
    if (hashLen >= 0) {
      const versionCursor = hashLen;
      const version38 = tryReadVersionString(header, versionCursor);
      if (version38 !== null) {
        const ver = spineVersionFromString(version38.trim());
        if (ver !== SpineVersion.UNKNOWN) {
          return ver;
        }
      }
    }
  }

  // 3. 兜底：头 1024 字节正则搜索版本号（如 "4.1.20" / "3.8.99"）
  return detectFromRawHeader(header);
}

/** 头部明文正则兜底。 */
function detectFromRawHeader(header: Uint8Array): SpineVersion {
  try {
    const decoder = util.TextDecoder.create('utf-8');
    // 有损解码：二进制垃圾字节被替换，不影响明文版本号搜索
    const text = decoder.decodeWithStream(header.subarray(0, Math.min(1024, header.length)),
      { stream: false });
    const v4 = /(?<![0-9])4\.([0-9]+)(?:\.[0-9]+)*/.exec(text);
    if (v4 !== null) {
      const minor = Number(v4[1]);
      if (!Number.isNaN(minor)) {
        const ver = spineVersionFromMajorMinor(4, minor);
        if (ver !== SpineVersion.UNKNOWN) {
          return ver;
        }
      }
    }
    const v3 = /(?<![0-9])3\.([5-8])(?:\.[0-9]+)*/.exec(text);
    if (v3 !== null) {
      const minor = Number(v3[1]);
      if (!Number.isNaN(minor)) {
        return spineVersionFromMajorMinor(3, minor);
      }
    }
  } catch (err) {
    console.error(`${TAG} detectFromRawHeader failed: ${JSON.stringify(err)}`);
  }
  return SpineVersion.UNKNOWN;
}

/** 读取文件头指定字节数到 Uint8Array，文件不存在或过短返回 null。 */
function readHeaderBytes(fileFullPath: string, maxBytes: number): Uint8Array | null {
  if (!fileIo.accessSync(fileFullPath, fileIo.AccessModeType.EXIST)) {
    return null;
  }
  const file = fileIo.openSync(fileFullPath, fileIo.OpenMode.READ_ONLY);
  try {
    const size = fileIo.statSync(file.fd).size;
    if (size < 8) {
      return null;
    }
    const toRead = Math.min(maxBytes, size);
    const buffer = new ArrayBuffer(toRead);
    const read = fileIo.readSync(file.fd, buffer, { length: toRead });
    return new Uint8Array(buffer, 0, read);
  } finally {
    fileIo.closeSync(file);
  }
}

/**
 * 从 cursor 起读一个 skel 字符串并去掉首尾空白后返回；
 * 读取失败（越界/空串）返回 null。
 */
function tryReadVersionString(header: Uint8Array, cursor: number): string | null {
  const value = tryReadSkelString(header, cursor);
  if (value === null || value.trim().length === 0) {
    return null;
  }
  return value;
}

/**
 * 从 cursor 起模拟 SkeletonInput.readString()：
 * varint 长度前缀 + UTF-8 字节。byteCount==1 表示空串（返回 null 表示无效）。
 * 返回 null 表示读取失败（EOF 或空串）。
 */
function tryReadSkelString(header: Uint8Array, cursor: number): string | null {
  let pos = cursor;
  const byteCount = readVarintAt(header, pos);
  if (byteCount < 0) {
    return null;
  }
  // varint 本身占用的字节数
  pos += varintEncodedLength(byteCount);
  if (byteCount <= 1) {
    return byteCount === 1 ? '' : null;
  }
  const byteLen = byteCount - 1;
  if (pos + byteLen > header.length) {
    return null;
  }
  try {
    const decoder = util.TextDecoder.create('utf-8');
    return decoder.decodeWithStream(header.subarray(pos, pos + byteLen), { stream: false });
  } catch (err) {
    console.error(`${TAG} decode skel string failed: ${JSON.stringify(err)}`);
    return null;
  }
}

/**
 * 返回从 cursor 开始的一个 skel 字符串在头内的总长度
 * （varint 占用 + 内容字节），失败返回 -1。用于 3.8 hash 定位 version 起始。
 */
function skelStringLength(header: Uint8Array, cursor: number): number {
  const byteCount = readVarintAt(header, cursor);
  if (byteCount < 0) {
    return -1;
  }
  const varintLen = varintEncodedLength(byteCount);
  if (byteCount === 0) {
    return varintLen;
  }
  const byteLen = byteCount - 1;
  if (cursor + varintLen + byteLen > header.length) {
    return -1;
  }
  return varintLen + byteLen;
}

/** 无符号 varint 值的编码长度（7bit 分组数）。 */
function varintEncodedLength(value: number): number {
  if (value === 0) {
    return 1;
  }
  let v = value;
  let len = 0;
  while (v > 0) {
    len++;
    v = Math.floor(v / 128);
  }
  return len;
}

/**
 * 模拟 SkeletonInput.readInt(true)：
 * 7-bit 分组 varint（无符号）。EOF 返回 -1。
 */
function readVarintAt(header: Uint8Array, cursor: number): number {
  if (cursor >= header.length) {
    return -1;
  }
  let b = header[cursor];
  let result = b & 0x7f;
  let pos = cursor + 1;
  if ((b & 0x80) !== 0) {
    if (pos >= header.length) {
      return -1;
    }
    b = header[pos];
    pos++;
    result = result | ((b & 0x7f) << 7);
    if ((b & 0x80) !== 0) {
      if (pos >= header.length) {
        return -1;
      }
      b = header[pos];
      pos++;
      result = result | ((b & 0x7f) << 14);
      if ((b & 0x80) !== 0) {
        if (pos >= header.length) {
          return -1;
        }
        b = header[pos];
        pos++;
        result = result | ((b & 0x7f) << 21);
        if ((b & 0x80) !== 0) {
          if (pos >= header.length) {
            return -1;
          }
          b = header[pos];
          result = result | ((b & 0x7f) << 28);
        }
      }
    }
  }
  return result;
}
