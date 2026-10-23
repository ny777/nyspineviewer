/**
 * 截帧状态机：命令下发、base64 分块聚合、超时守卫与结果路由。
 * 自 Index.ets 抽出；capturing 的 @State 仍由宿主（Index）持有，经 deps 回调同步。
 */
import { BridgeCmdNames, BridgeCommand, parseCaptureChunkEvent, parseCaptureFrameEvent } from '../core/BridgeProtocol';

/** 截帧超时上限（毫秒）。 */
const CAPTURE_TIMEOUT_MS = 15000;

/** 截帧用途：保存到图库 / 自动更新卡片 / 手动更新卡片 / 缩略图管线。 */
export const CAPTURE_PURPOSE_GALLERY: string = 'gallery';
export const CAPTURE_PURPOSE_WIDGET: string = 'widget';
export const CAPTURE_PURPOSE_WIDGET_MANUAL: string = 'widget-manual';
export const CAPTURE_PURPOSE_THUMB: string = 'thumb';

/** 截帧协调器依赖（宿主注入闭包）。 */
export interface CaptureDeps {
  sendCommand: (command: BridgeCommand) => void;
  isWebReady: () => boolean;
  setCapturing: (capturing: boolean) => void;
  /** base64 分块聚合完整（CAPTURE_FRAME done 且分块齐全）。 */
  onCaptureComplete: (base64: string, purpose: string) => void;
  /** 截帧失败：超时 / CAPTURE_ERROR / 分块缺失。 */
  onCaptureFail: (purpose: string) => void;
}

export class CaptureCoordinator {
  private readonly deps: CaptureDeps;
  private chunks: Array<string> = [];
  private total: number = 0;
  private timerId: number = -1;
  private purpose: string = CAPTURE_PURPOSE_GALLERY;
  private running: boolean = false;

  constructor(deps: CaptureDeps) {
    this.deps = deps;
  }

  /** 发起截帧（进行中或 Web 未就绪时忽略）。 */
  start(purpose: string): void {
    if (this.running || !this.deps.isWebReady()) {
      return;
    }
    this.running = true;
    this.purpose = purpose;
    this.chunks = [];
    this.total = 0;
    this.deps.setCapturing(true);
    this.deps.sendCommand({ cmd: BridgeCmdNames.CAPTURE_FRAME });
    this.timerId = setTimeout((): void => {
      this.timerId = -1;
      if (this.running) {
        this.fail();
      }
    }, CAPTURE_TIMEOUT_MS);
  }

  /** Bridge 上报 CAPTURE_ERROR 时中止（失败统一走 onCaptureFail 路由）。 */
  abort(): void {
    if (this.running) {
      this.fail();
    }
  }

  handleChunk(json: string): void {
    const event = parseCaptureChunkEvent(json);
    if (event === null) {
      return;
    }
    if (event.index === 0) {
      this.chunks = [];
      this.total = event.total;
    }
    if (event.total !== this.total || event.index !== this.chunks.length) {
      return;
    }
    this.chunks.push(event.data);
  }

  handleDone(json: string): void {
    const event = parseCaptureFrameEvent(json);
    if (event === null || !event.done) {
      return;
    }
    if (!this.running) {
      return;
    }
    if (this.total === 0 || this.chunks.length !== this.total) {
      this.fail();
      return;
    }
    const base64 = this.chunks.join('');
    this.chunks = [];
    this.total = 0;
    this.running = false;
    this.clearTimer();
    this.deps.setCapturing(false);
    this.deps.onCaptureComplete(base64, this.purpose);
  }

  dispose(): void {
    this.clearTimer();
  }

  private fail(): void {
    this.running = false;
    this.clearTimer();
    this.deps.setCapturing(false);
    this.deps.onCaptureFail(this.purpose);
  }

  private clearTimer(): void {
    if (this.timerId >= 0) {
      clearTimeout(this.timerId);
      this.timerId = -1;
    }
  }
}
