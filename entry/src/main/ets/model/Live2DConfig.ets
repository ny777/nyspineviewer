/**
 * Live2DViewerEX 风格 config.json 解析（移植自 Live2DConfig.kt）。
 * 单次 JSON.parse 归一化为显式接口，再逐字段校验拷贝。
 */

/** config.json 解析结果。 */
export class Live2DConfig {
  scale: number;
  /** 待机动作名，空串表示未指定。 */
  idle_motion: string;
  tap_motions: Map<string, string>;

  constructor() {
    this.scale = 1.0;
    this.idle_motion = '';
    this.tap_motions = new Map<string, string>();
  }
}

/** config.json 原始结构（仅用于 JSON.parse 单次断言归一）。 */
interface Live2DConfigRaw {
  scale?: Object;
  idle_motion?: Object;
  tap_motions?: Record<string, Object>;
}

/**
 * 解析 config.json 文本；任何结构性错误返回 null（调用方按「无 config」处理）。
 */
export function parseLive2DConfig(jsonText: string): Live2DConfig | null {
  let parsed: object | null = null;
  try {
    parsed = JSON.parse(jsonText);
  } catch (err) {
    return null;
  }
  if (parsed === null) {
    return null;
  }
  const raw = parsed as Live2DConfigRaw;
  const config = new Live2DConfig();

  if (typeof raw.scale === 'number' && Number.isFinite(raw.scale) && raw.scale > 0) {
    config.scale = raw.scale;
  }
  if (typeof raw.idle_motion === 'string' && raw.idle_motion.length > 0) {
    config.idle_motion = raw.idle_motion;
  }

  if (raw.tap_motions !== undefined && raw.tap_motions !== null) {
    const keys = Object.keys(raw.tap_motions);
    for (const key of keys) {
      const value = raw.tap_motions[key];
      if (typeof value === 'string' && key.length > 0) {
        config.tap_motions.set(key, value);
      }
    }
  }

  return config;
}
