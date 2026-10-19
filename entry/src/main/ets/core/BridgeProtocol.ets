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
  static readonly SET_GESTURE_SLOT: string = 'setGestureSlot';
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

/** Web→ArkTS：截帧分块回传（256KB base64 切片）。 */
export interface CaptureChunkEvent {
  index: number;
  total: number;
  data: string;
}

/** Web→ArkTS：截帧分块传输完成信号。 */
export interface CaptureFrameEvent {
  done: boolean;
}

/** Web→ArkTS：手势结束后的变换回传（持久化用）。 */
export interface TransformChangedEvent {
  slot: number;
  scale: number;
  x: number;
  y: number;
}

/** Web→ArkTS：点按切换动画后的回传（UI 下拉框同步）。 */
export interface AnimationChangedEvent {
  slot: number;
  name: string;
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

interface CaptureChunkRaw {
  index?: Object;
  total?: Object;
  data?: Object;
}

interface CaptureFrameRaw {
  done?: Object;
}

interface TransformChangedRaw {
  slot?: Object;
  scale?: Object;
  x?: Object;
  y?: Object;
}

interface AnimationChangedRaw {
  slot?: Object;
  name?: Object;
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

/** 解析 onCaptureFrameChunk 回传 JSON（截帧分块）。 */
export function parseCaptureChunkEvent(json: string): CaptureChunkEvent | null {
  let parsed: object | null = null;
  try {
    parsed = JSON.parse(json);
  } catch (err) {
    return null;
  }
  if (parsed === null) {
    return null;
  }
  const raw = parsed as CaptureChunkRaw;
  if (typeof raw.index !== 'number' || typeof raw.total !== 'number' ||
    typeof raw.data !== 'string' || !Number.isInteger(raw.index) ||
    !Number.isInteger(raw.total) || raw.index < 0 || raw.total < 1 ||
    raw.index >= raw.total || raw.data.length === 0) {
    return null;
  }
  const index: number = raw.index;
  const total: number = raw.total;
  const data: string = raw.data;
  return { index: index, total: total, data: data };
}

/** 解析 onCaptureFrame 回传 JSON（分块传输完成信号）。 */
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
  if (typeof raw.done !== 'boolean') {
    return null;
  }
  const done: boolean = raw.done;
  return { done: done };
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

/** 解析 onAnimationChanged 回传 JSON。 */
export function parseAnimationChangedEvent(json: string): AnimationChangedEvent | null {
  let parsed: object | null = null;
  try {
    parsed = JSON.parse(json);
  } catch (err) {
    return null;
  }
  if (parsed === null) {
    return null;
  }
  const raw = parsed as AnimationChangedRaw;
  if (typeof raw.slot !== 'number' || typeof raw.name !== 'string') {
    return null;
  }
  const slot: number = raw.slot;
  const name: string = raw.name;
  return { slot: slot, name: name };
}

/** 把 Object[] 逐项校验为 string[]，任何非字符串项返回 null。 */
function toStringArray(value: Array<Object> | undefined): Array<string> | null {
  if (value === undefined || value === null) {
    return null;
  }
  const result: Array<string> = [];
  try {
    for (const item of value) {
      if (typeof item !== 'string') {
        return null;
      }
      result.push(item);
    }
  } catch (err) {
    // 字段实际不是数组（恶意/损坏回传），按非法处理
    return null;
  }
  return result;
}

/** 序列化命令为注入 JS 的调用串：window.SpineHost.cmd({...})。 */
export function buildRunScript(command: BridgeCommand): string {
  const json = JSON.stringify(command);
  return `window.SpineHost && window.SpineHost.cmd(${json});`;
}
