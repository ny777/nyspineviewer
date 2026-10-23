/**
 * 支持的 Spine 运行时主版本枚举（对齐 Android 版 SpineVersion.kt）。
 */
export enum SpineVersion {
  V36,
  V37,
  V38,
  V40,
  V41,
  V42,
  V43,
  V43B,
  UNKNOWN
}

/** 版本字符串解析：4.3 带 beta 后缀归入 4.3.39 dev 窗口（V43B）。 */
export function spineVersionFromString(versionStr: string | null): SpineVersion {
  if (versionStr === null || versionStr.length === 0) {
    return SpineVersion.UNKNOWN;
  }
  const clean = versionStr.trim().toLowerCase();
  if (clean.startsWith('3.5') || clean.startsWith('3.6')) {
    return SpineVersion.V36;
  }
  if (clean.startsWith('3.7')) {
    return SpineVersion.V37;
  }
  if (clean.startsWith('3.8')) {
    return SpineVersion.V38;
  }
  if (clean.startsWith('4.0')) {
    return SpineVersion.V40;
  }
  if (clean.startsWith('4.1')) {
    return SpineVersion.V41;
  }
  if (clean.startsWith('4.2')) {
    return SpineVersion.V42;
  }
  if (clean.startsWith('4.3') && clean.includes('beta')) {
    return SpineVersion.V43B;
  }
  if (clean.startsWith('4.3')) {
    return SpineVersion.V43;
  }
  return SpineVersion.UNKNOWN;
}

/** 由 major.minor 构造版本枚举，未知返回 UNKNOWN。 */
export function spineVersionFromMajorMinor(major: number, minor: number): SpineVersion {
  return spineVersionFromString(`${major}.${minor}`);
}

/** 枚举转短版本串（如 "4.1"），用于徽章显示与 runtime bundle 选择。 */
export function spineVersionToString(version: SpineVersion): string {
  switch (version) {
    case SpineVersion.V36:
      return '3.6';
    case SpineVersion.V37:
      return '3.7';
    case SpineVersion.V38:
      return '3.8';
    case SpineVersion.V40:
      return '4.0';
    case SpineVersion.V41:
      return '4.1';
    case SpineVersion.V42:
      return '4.2';
    case SpineVersion.V43:
      return '4.3';
    case SpineVersion.V43B:
      return '4.3.39-beta';
    default:
      return 'unknown';
  }
}

