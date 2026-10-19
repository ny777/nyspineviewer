/**
 * Live2DViewerEX 风格 config.json 解析（移植自 Live2DConfig.kt）。
 * 单次 JSON.parse 归一化为显式接口，再逐字段校验拷贝。
 */

/** 动作描述。 */
export class Live2DMotion {
  file: string;
  track: number;
  loop: boolean;
  /** 可选动作别名，空串表示未指定。 */
  name: string;

  constructor(file: string, track: number, loop: boolean, name: string) {
    this.file = file;
    this.track = track;
    this.loop = loop;
    this.name = name;
  }
}

/** config.json 解析结果。 */
export class Live2DConfig {
  version: string;
  model: string;
  atlas: string;
  /** 可选显示名，空串表示未指定。 */
  name: string;
  scale: number;
  posX: number;
  posY: number;
  /** 待机动作名，空串表示未指定。 */
  idle_motion: string;
  tap_motions: Map<string, string>;
  motions: Array<Live2DMotion>;
  skins: Array<string>;

  constructor() {
    this.version = '1.0.0';
    this.model = '';
    this.atlas = '';
    this.name = '';
    this.scale = 1.0;
    this.posX = 0.0;
    this.posY = 0.0;
    this.idle_motion = '';
    this.tap_motions = new Map<string, string>();
    this.motions = new Array<Live2DMotion>();
    this.skins = new Array<string>();
  }
}

/** config.json 原始结构（仅用于 JSON.parse 单次断言归一）。 */
interface Live2DMotionRaw {
  file?: Object;
  track?: Object;
  loop?: Object;
  name?: Object;
}

interface PositionRaw {
  x?: Object;
  y?: Object;
}

interface Live2DConfigRaw {
  version?: Object;
  model?: Object;
  atlas?: Object;
  name?: Object;
  scale?: Object;
  position?: PositionRaw;
  idle_motion?: Object;
  tap_motions?: Record<string, Object>;
  motions?: Array<Live2DMotionRaw>;
  skins?: Array<Object>;
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

  if (typeof raw.version === 'string' && raw.version.length > 0) {
    config.version = raw.version;
  }
  if (typeof raw.model === 'string') {
    config.model = raw.model;
  }
  if (typeof raw.atlas === 'string') {
    config.atlas = raw.atlas;
  }
  if (typeof raw.name === 'string' && raw.name.length > 0) {
    config.name = raw.name;
  }
  if (typeof raw.scale === 'number' && Number.isFinite(raw.scale) && raw.scale > 0) {
    config.scale = raw.scale;
  }
  if (raw.position !== undefined && raw.position !== null) {
    if (typeof raw.position.x === 'number' && Number.isFinite(raw.position.x)) {
      config.posX = raw.position.x;
    }
    if (typeof raw.position.y === 'number' && Number.isFinite(raw.position.y)) {
      config.posY = raw.position.y;
    }
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

  if (raw.motions !== undefined && raw.motions !== null) {
    for (const motionRaw of raw.motions) {
      if (typeof motionRaw.file !== 'string' || motionRaw.file.length === 0) {
        continue;
      }
      let track = 0;
      let loop = true;
      let name = '';
      if (typeof motionRaw.track === 'number' && Number.isFinite(motionRaw.track)) {
        track = Math.trunc(motionRaw.track);
      }
      if (typeof motionRaw.loop === 'boolean') {
        loop = motionRaw.loop;
      }
      if (typeof motionRaw.name === 'string') {
        name = motionRaw.name;
      }
      const file: string = motionRaw.file;
      config.motions.push(new Live2DMotion(file, track, loop, name));
    }
  }

  if (raw.skins !== undefined && raw.skins !== null) {
    for (const skin of raw.skins) {
      if (typeof skin === 'string' && skin.length > 0) {
        config.skins.push(skin);
      }
    }
  }

  return config;
}
