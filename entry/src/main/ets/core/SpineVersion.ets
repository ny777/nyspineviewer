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

/** 展示名（对齐 Android 版 displayName）。 */
export function spineVersionDisplayName(version: SpineVersion): string {
  switch (version) {
    case SpineVersion.V36:
      return 'Spine 3.5 / 3.6 (老格式)';
    case SpineVersion.V37:
      return 'Spine 3.7 (老格式)';
    case SpineVersion.V38:
      return 'Spine 3.8 (主流游戏通用)';
    case SpineVersion.V40:
      return 'Spine 4.0 (过渡版本)';
    case SpineVersion.V41:
      return 'Spine 4.1 (现代官方标准)';
    case SpineVersion.V42:
      return 'Spine 4.2 (次时代物理引擎)';
    case SpineVersion.V43:
      return 'Spine 4.3 (最新标准)';
    case SpineVersion.V43B:
      return 'Spine 4.3 beta (4.3.39 中间格式)';
    default:
      return '未知版本';
  }
}

/**
 * 降级尝试顺序（对齐 Android 版 SpineMultiRuntimeManager）：
 * 目标版本优先，其次按版本从新到旧逐级降级。
 * V43B 必须排在 V43 之后（先让 4.3.5 试，再交给 4.3.39-beta）。
 */
export function spineVersionFallbackOrder(preferred: SpineVersion): Array<SpineVersion> {
  const order: Array<SpineVersion> = [preferred];
  const rest: Array<SpineVersion> = [
    SpineVersion.V43, SpineVersion.V43B, SpineVersion.V42, SpineVersion.V41,
    SpineVersion.V40, SpineVersion.V38, SpineVersion.V37, SpineVersion.V36
  ];
  for (const v of rest) {
    if (!order.includes(v)) {
      order.push(v);
    }
  }
  return order;
}
