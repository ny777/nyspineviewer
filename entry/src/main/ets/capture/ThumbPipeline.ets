/**
 * 缩略图补全管线：逐模型临时加载到槽 0 → 等就绪 → 稳帧 → 截帧落盘，串行执行，
 * 结束后恢复主模型（含隐藏状态）。运行期间宿主须抑制 widget 自动截帧与动画轮换。
 * 自 Index.ets 抽出。
 */
import { Context } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { BridgeCmdNames, BridgeCommand } from '../core/BridgeProtocol';
import { SpineModelLibrary } from '../model/SpineModelLibrary';
import { SpineModelItem } from '../model/SpineModelItem';
import { sanitizeAtlas } from '../model/AtlasSanitizer';
import { ThumbStore } from './ThumbStore';
import { CAPTURE_PURPOSE_THUMB } from './CaptureCoordinator';

/** 单模型加载等待上限（MODEL_READY 未回传则跳过）。 */
const THUMB_MODEL_TIMEOUT_MS = 4000;
/** 模型就绪后的稳帧等待。 */
const THUMB_SETTLE_MS = 400;
const LOG_DOMAIN = 0x0031;
const TAG = 'ThumbPipeline';

/** 缩略图管线依赖（宿主注入闭包）。 */
export interface ThumbDeps {
  getContext: () => Context;
  library: () => SpineModelLibrary | null;
  sendCommand: (command: BridgeCommand) => void;
  startCapture: (purpose: string) => void;
  isWebReady: () => boolean;
  isCapturing: () => boolean;
  setModelLoading: (loading: boolean) => void;
  isModelLoading: () => boolean;
  setGenerating: (generating: boolean) => void;
  isGenerating: () => boolean;
  setProgress: (current: number, total: number) => void;
  getMainModelId: () => string;
  getSlotPma: (slot: number) => boolean;
  isMainSlotHidden: () => boolean;
  onThumbSaved: (modelId: string) => void;
  /** 管线结束后恢复主模型（含隐藏状态还原）。 */
  restoreMainSlot: (mainWasHidden: boolean) => void;
  /** 结果提示（成功 / 部分成功）。 */
  showResult: (okCount: number, total: number) => void;
}

export class ThumbPipeline {
  private readonly deps: ThumbDeps;
  private pendingModelId: string = '';
  private captureResolve: ((ok: boolean) => void) | null = null;

  constructor(deps: ThumbDeps) {
    this.deps = deps;
  }

  /** 截帧数据完整回调（宿主从 onCaptureComplete(purpose==thumb) 转发）。 */
  onFrameComplete(base64: string): void {
    const thumbId = this.pendingModelId;
    ThumbStore.saveThumb(this.deps.getContext(), base64, thumbId)
      .then((): void => {
        this.deps.onThumbSaved(thumbId);
        this.resolveCapture(true);
      })
      .catch((err: BusinessError): void => {
        this.resolveCapture(false);
      });
  }

  /** 截帧失败/中止回调（宿主从 onCaptureFail(purpose==thumb) 转发）。 */
  resolveCapture(ok: boolean): void {
    const r = this.captureResolve;
    this.captureResolve = null;
    if (r !== null) {
      r(ok);
    }
  }

  /** 收集缺少缩略图且可渲染的模型并启动补全管线。 */
  startForMissing(models: Array<SpineModelItem>): void {
    if (this.deps.isGenerating()) {
      return;
    }
    const ids = new Array<string>();
    for (const m of models) {
      if (!m.hasThumb && m.isSupported()) {
        ids.push(m.id);
      }
    }
    if (ids.length > 0) {
      this.generate(ids);
    }
  }

  /**
   * 串行生成缩略图：逐个加载到槽 0 → 稳帧 → 截帧存缩略图，完成后恢复主模型。
   * 运行期间抑制 widget 自动截帧（宿主 scheduleCapture guard）。
   */
  async generate(ids: Array<string>): Promise<void> {
    const library = this.deps.library();
    if (library === null || this.deps.isGenerating() || ids.length === 0) {
      return;
    }
    this.deps.setGenerating(true);
    this.deps.setProgress(0, ids.length);
    const restoreId = this.deps.getMainModelId();
    // 管线会 LOAD_MODEL 到槽 0（Web 端加载即显示）：结束后需恢复用户原本对主模型的隐藏状态
    const mainWasHidden = this.deps.isMainSlotHidden();
    let okCount = 0;
    let current = 0;
    try {
      for (const id of ids) {
        const model = library.getModelById(id);
        if (model === null || !model.isSupported()) {
          continue;
        }
        current++;
        this.deps.setProgress(current, ids.length);
        await this.loadModelForThumb(model);
        const ready = await this.waitUntil((): boolean => !this.deps.isModelLoading(), THUMB_MODEL_TIMEOUT_MS);
        if (!ready) {
          this.deps.setModelLoading(false);
          hilog.warn(LOG_DOMAIN, TAG, 'thumb model load timeout id=%{public}s', id);
          continue;
        }
        await this.delay(THUMB_SETTLE_MS);
        if (this.deps.isCapturing() || !this.deps.isWebReady()) {
          continue;
        }
        this.pendingModelId = id;
        const captured = new Promise<boolean>((resolve: (ok: boolean) => void) => {
          this.captureResolve = resolve;
        });
        this.deps.startCapture(CAPTURE_PURPOSE_THUMB);
        if (await captured) {
          okCount++;
          hilog.info(LOG_DOMAIN, TAG, 'thumb saved id=%{public}s', id);
        }
      }
    } finally {
      this.deps.setGenerating(false);
      this.captureResolve = null;
      this.pendingModelId = '';
      this.deps.setProgress(0, 0);
      if (restoreId.length > 0 && restoreId === this.deps.getMainModelId()) {
        this.deps.restoreMainSlot(mainWasHidden);
      }
    }
    this.deps.showResult(okCount, ids.length);
  }

  /** 管线专用加载：LOAD_MODEL 到槽 0，不写偏好、不改主模型 id。 */
  private async loadModelForThumb(model: SpineModelItem): Promise<void> {
    const library = this.deps.library();
    if (library === null) {
      return;
    }
    let atlasFile = model.atlasFile;
    if (atlasFile.length > 0) {
      const sanitized = await sanitizeAtlas(model.atlasPath());
      atlasFile = sanitized.atlasFile;
    }
    const config = library.readModelConfig(model);
    this.deps.setModelLoading(true);
    this.deps.sendCommand({
      cmd: BridgeCmdNames.LOAD_MODEL,
      slot: 0,
      modelId: model.id,
      skelFile: model.skelFile,
      atlasFile: atlasFile,
      version: model.version,
      pma: this.deps.getSlotPma(0),
      configScale: config !== null ? config.scale : 1,
      idleMotion: config !== null ? config.idle_motion : ''
    });
    this.deps.sendCommand({ cmd: BridgeCmdNames.SET_TRANSFORM, slot: 0, scale: 1, x: 0, y: 0 });
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: (v: void) => void) => {
      setTimeout(resolve, ms);
    });
  }

  /** 轮询等待条件成立（100ms 间隔，超时返回 false）。 */
  private waitUntil(cond: () => boolean, timeoutMs: number): Promise<boolean> {
    const deadline = Date.now() + timeoutMs;
    return new Promise<boolean>((resolve: (ok: boolean) => void) => {
      const check = (): void => {
        if (cond()) {
          resolve(true);
        } else if (Date.now() > deadline) {
          resolve(false);
        } else {
          setTimeout(check, 100);
        }
      };
      setTimeout(check, 100);
    });
  }
}
