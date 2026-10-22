/**
 * 桌面卡片协调器：模型加载后延时自动截帧、快照落盘与全部卡片刷新。
 * 自 Index.ets 抽出；卡片表单登记 / 快照存储 / 推送由 WidgetStore 提供。
 */
import { Context } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { WidgetFormsStore, WidgetSnapshotStore, WidgetUpdater } from './WidgetStore';
import { ThumbStore } from '../capture/ThumbStore';
import { CAPTURE_PURPOSE_WIDGET, CAPTURE_PURPOSE_WIDGET_MANUAL } from '../capture/CaptureCoordinator';

/** 模型加载后延时截帧更新卡片（等首帧稳定）。 */
const WIDGET_CAPTURE_DELAY_MS = 800;
const LOG_DOMAIN = 0x0031;
const TAG = 'WidgetCoordinator';

/** 卡片协调器依赖（宿主注入闭包）。 */
export interface WidgetDeps {
  getContext: () => Context;
  isAutoUpdateEnabled: () => boolean;
  isThumbGenerating: () => boolean;
  isCapturing: () => boolean;
  isWebReady: () => boolean;
  getMainModelId: () => string;
  getMainModelName: () => string;
  setCapturing: (capturing: boolean) => void;
  markThumbGenerated: (modelId: string) => void;
  startCapture: (purpose: string) => void;
  showToast: (message: ResourceStr) => void;
}

export class WidgetCoordinator {
  private readonly deps: WidgetDeps;
  private captureTimerId: number = -1;

  constructor(deps: WidgetDeps) {
    this.deps = deps;
  }

  /** 手动"立即更新卡片"：截取当前帧更新快照并刷新卡片。 */
  updateNow(): void {
    this.deps.startCapture(CAPTURE_PURPOSE_WIDGET_MANUAL);
  }

  /** 模型加载后延时截帧更新卡片（等首帧稳定；仅已添加卡片时执行）。 */
  scheduleCapture(): void {
    this.clearTimer();
    this.captureTimerId = setTimeout((): void => {
      this.captureTimerId = -1;
      if (!this.deps.isAutoUpdateEnabled() || this.deps.isThumbGenerating() ||
        this.deps.isCapturing() || !this.deps.isWebReady()) {
        return;
      }
      const ids = WidgetFormsStore.readFormIds(this.deps.getContext());
      if (ids.length > 0) {
        this.deps.startCapture(CAPTURE_PURPOSE_WIDGET);
      }
    }, WIDGET_CAPTURE_DELAY_MS);
  }

  /** 保存快照并刷新全部卡片（widget 截帧完成路径）。 */
  saveSnapshot(base64: string, showResult: boolean): void {
    const context = this.deps.getContext();
    const title = this.deps.getMainModelName();
    try {
      WidgetSnapshotStore.saveSnapshot(context, base64, title);
    } catch (err) {
      this.deps.setCapturing(false);
      hilog.warn(LOG_DOMAIN, TAG, 'save widget snapshot failed');
      if (showResult) {
        this.deps.showToast($r('app.string.toast_capture_fail'));
      }
      return;
    }
    // 卡片快照与主模型画面一致，顺带落一份缩略图（缩略主模型随用随得）
    if (!this.deps.isThumbGenerating() && this.deps.getMainModelId().length > 0) {
      const mainId = this.deps.getMainModelId();
      ThumbStore.saveThumb(context, base64, mainId)
        .then((): void => {
          this.deps.markThumbGenerated(mainId);
        })
        .catch((err: BusinessError): void => {
          hilog.warn(LOG_DOMAIN, TAG, 'save thumb piggyback failed');
        });
    }
    WidgetUpdater.updateAll(context)
      .then((): void => {
        this.deps.setCapturing(false);
        if (showResult) {
          this.deps.showToast($r('app.string.toast_widget_updated'));
        }
      })
      .catch((err: BusinessError): void => {
        this.deps.setCapturing(false);
        if (showResult) {
          this.deps.showToast($r('app.string.toast_capture_fail'));
        }
      });
  }

  /** 保存到图库成功后顺带刷新卡片（自动更新开启时复用同一帧）。 */
  updateFromFrame(base64: string): void {
    if (!this.deps.isAutoUpdateEnabled()) {
      return;
    }
    const context = this.deps.getContext();
    const ids = WidgetFormsStore.readFormIds(context);
    if (ids.length === 0) {
      return;
    }
    try {
      WidgetSnapshotStore.saveSnapshot(context, base64, this.deps.getMainModelName());
      WidgetUpdater.updateAll(context).catch((err: BusinessError): void => {
        hilog.warn(LOG_DOMAIN, TAG, 'update widget after capture failed');
      });
    } catch (err) {
      hilog.warn(LOG_DOMAIN, TAG, 'save widget snapshot after capture failed');
    }
  }

  dispose(): void {
    this.clearTimer();
  }

  private clearTimer(): void {
    if (this.captureTimerId >= 0) {
      clearTimeout(this.captureTimerId);
      this.captureTimerId = -1;
    }
  }
}
