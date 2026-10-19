/**
 * ArkTS ↔ WebView 双向消息协议（player-host.js 双端实现，字段保持一致）。
 * ArkTS→Web 经 runJavaScript('window.SpineHost.cmd(<json>)')；
 * Web→ArkTS 经 javaScriptProxy 注册的 spineBridge 对象回调。
 */

/** ArkTS→Web 命令（所有可选字段按命令类型取用，禁止臆造字段）。 */
export interface BridgeCommand {
  cmd: string;
  /** 槽位：0 主模型（前层）、1 副模型（后层）。 */
  slot?: number;
  modelId?: string;
  skelFile?: string;
  atlasFile?: string;
  /** Spine 短版本串，如 "4.1"，用于选择 runtime bundle。 */
  version?: string;
  pma?: boolean;
  name?: string;
  loop?: boolean;
  /** 多选皮肤：首项为基底，其余叠加。 */
  skins?: Array<string>;
  scale?: number;
  x?: number;
  y?: number;
  playing?: boolean;
  fps?: number;
  color?: string;
}

/** 命令名常量，避免拼写漂移。 */
export class BridgeCmdNames {
  static readonly LOAD_MODEL: string = 'loadModel';
  static readonly PLAY_ANIMATION: string = 'playAnimation';
  static readonly SET_SKINS: string = 'setSkins';
  static readonly SET_TRANSFORM: string = 'setTransform';
  static readonly SET_PMA: string = 'setPma';
  static readonly SET_PLAYING: string = 'setPlaying';
  static readonly SET_FPS: string = 'setFps';
  static readonly SET_BG_COLOR: string = 'setBackgroundColor';
  static readonly CAPTURE_FRAME: string = 'captureFrame';
  static readonly CLEAR_SLOT: string = 'clearSlot';
}

/** Web→ArkTS：模型加载完成事件。 */
export interface ModelLoadedEvent {
  slot: number;
  modelId: string;
  animations: Array<string>;
  skins: Array<string>;
}

/** Web→ArkTS：错误事件。 */
export interface BridgeErrorEvent {
  slot: number;
  code: string;
  message: string;
}

/** Web→ArkTS：截帧回传。 */
export interface CaptureFrameEvent {
  base64Png: string;
}

/** Web→ArkTS：手势结束后的变换回传（持久化用）。 */
export interface TransformChangedEvent {
  slot: number;
  scale: number;
  x: number;
  y: number;
}

// 以下 raw 接口仅用于 JSON.parse 单次断言归一，逐字段 typeof 校验后拷入严格事件。

interface ModelLoadedRaw {
  slot?: Object;
  modelId?: Object;
  animations?: Array<Object>;
  skins?: Array<Object>;
}

interface BridgeErrorRaw {
  slot?: Object;
  code?: Object;
  message?: Object;
}

interface CaptureFrameRaw {
  base64Png?: Object;
}

interface TransformChangedRaw {
  slot?: Object;
  scale?: Object;
  x?: Object;
  y?: Object;
}

/**
 * 解析 onModelLoaded 回传的 JSON 字符串为 ModelLoadedEvent；
 * 任何字段非法返回 null（显式校验，不做类型断言直通）。
 */
export function parseModelLoadedEvent(json: string): ModelLoadedEvent | null {
  let parsed: object | null = null;
  try {
    parsed = JSON.parse(json);
  } catch (err) {
    return null;
  }
  if (parsed === null) {
    return null;
  }
  const raw = parsed as ModelLoadedRaw;
  if (typeof raw.slot !== 'number' || typeof raw.modelId !== 'string') {
    return null;
  }
  const animations = toStringArray(raw.animations);
  const skins = toStringArray(raw.skins);
  if (animations === null || skins === null) {
    return null;
  }
  const slot: number = raw.slot;
  const modelId: string = raw.modelId;
  return { slot: slot, modelId: modelId, animations: animations, skins: skins };
}

/** 解析 onError 回传 JSON。 */
export function parseBridgeErrorEvent(json: string): BridgeErrorEvent | null {
  let parsed: object | null = null;
  try {
    parsed = JSON.parse(json);
  } catch (err) {
    return null;
  }
  if (parsed === null) {
    return null;
  }
  const raw = parsed as BridgeErrorRaw;
  if (typeof raw.slot !== 'number' || typeof raw.code !== 'string' ||
    typeof raw.message !== 'string') {
    return null;
  }
  const slot: number = raw.slot;
  const code: string = raw.code;
  const message: string = raw.message;
  return { slot: slot, code: code, message: message };
}

/** 解析 onCaptureFrame 回传 JSON。 */
export function parseCaptureFrameEvent(json: string): CaptureFrameEvent | null {
  let parsed: object | null = null;
  try {
    parsed = JSON.parse(json);
  } catch (err) {
    return null;
  }
  if (parsed === null) {
    return null;
  }
  const raw = parsed as CaptureFrameRaw;
  if (typeof raw.base64Png !== 'string') {
    return null;
  }
  const base64Png: string = raw.base64Png;
  return { base64Png: base64Png };
}

/** 解析 onTransformChanged 回传 JSON。 */
export function parseTransformChangedEvent(json: string): TransformChangedEvent | null {
  let parsed: object | null = null;
  try {
    parsed = JSON.parse(json);
  } catch (err) {
    return null;
  }
  if (parsed === null) {
    return null;
  }
  const raw = parsed as TransformChangedRaw;
  if (typeof raw.slot !== 'number' || typeof raw.scale !== 'number' ||
    typeof raw.x !== 'number' || typeof raw.y !== 'number') {
    return null;
  }
  const slot: number = raw.slot;
  const scale: number = raw.scale;
  const x: number = raw.x;
  const y: number = raw.y;
  return { slot: slot, scale: scale, x: x, y: y };
}

/** 把 Object[] 逐项校验为 string[]，任何非字符串项返回 null。 */
function toStringArray(value: Object | undefined): Array<string> | null {
  if (!Array.isArray(value)) {
    return null;
  }
  const result: Array<string> = [];
  for (const item of value) {
    if (typeof item !== 'string') {
      return null;
    }
    result.push(item);
  }
  return result;
}

/** 序列化命令为注入 JS 的调用串：window.SpineHost.cmd({...})。 */
export function buildRunScript(command: BridgeCommand): string {
  const json = JSON.stringify(command);
  return `window.SpineHost && window.SpineHost.cmd(${json});`;
}
