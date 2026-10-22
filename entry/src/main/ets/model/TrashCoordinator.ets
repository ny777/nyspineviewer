/**
 * 回收站动作协调器：恢复 / 彻底删除 / 清空 / 过期清除。
 * 自 Index.ets 抽出；回收站弹窗与列表 @State 仍由宿主（Index）持有。
 */
import { Context } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { SpineModelLibrary } from './SpineModelLibrary';
import { ThumbStore } from '../capture/ThumbStore';

/** 回收站协调器依赖（宿主注入闭包）。 */
export interface TrashDeps {
  getContext: () => Context;
  library: () => SpineModelLibrary | null;
  showToast: (message: ResourceStr) => void;
  reloadModels: () => void;
  refreshTrashEntries: () => void;
}

export class TrashCoordinator {
  private readonly deps: TrashDeps;

  constructor(deps: TrashDeps) {
    this.deps = deps;
  }

  /** 回收站内恢复单个模型。 */
  restore(modelId: string): void {
    const library = this.deps.library();
    if (library === null) {
      return;
    }
    library.restoreFromTrash(modelId)
      .then((ok: boolean): void => {
        this.deps.refreshTrashEntries();
        if (ok) {
          this.deps.reloadModels();
          this.deps.showToast($r('app.string.toast_trash_restored'));
        }
      })
      .catch((err: BusinessError): void => {
        this.deps.showToast($r('app.string.toast_trash_restore_fail'));
      });
  }

  /** 回收站内彻底删除单个模型（含缩略图）。 */
  purge(modelId: string): void {
    const library = this.deps.library();
    if (library === null) {
      return;
    }
    library.purgeTrashEntry(modelId)
      .then((): void => {
        ThumbStore.deleteThumb(this.deps.getContext(), modelId);
        this.deps.refreshTrashEntries();
        this.deps.showToast($r('app.string.toast_trash_purged'));
      })
      .catch((err: BusinessError): void => {
        this.deps.showToast($r('app.string.toast_delete_fail'));
      });
  }

  /** 清空回收站（含全部缩略图）。 */
  empty(): void {
    const library = this.deps.library();
    if (library === null) {
      return;
    }
    library.emptyTrash()
      .then((purgedIds: Array<string>): void => {
        const context = this.deps.getContext();
        for (const id of purgedIds) {
          ThumbStore.deleteThumb(context, id);
        }
        this.deps.refreshTrashEntries();
        this.deps.showToast($r('app.string.toast_trash_emptied'));
      })
      .catch((err: BusinessError): void => {
        this.deps.showToast($r('app.string.toast_delete_fail'));
      });
  }

  /** 按保留策略清除过期回收站条目（retentionDays <= 0 永久保留）。 */
  purgeExpired(retentionDays: number): void {
    const library = this.deps.library();
    if (library === null || retentionDays <= 0) {
      return;
    }
    library.purgeExpiredTrash(retentionDays)
      .then((purgedIds: Array<string>): void => {
        if (purgedIds.length === 0) {
          return;
        }
        const context = this.deps.getContext();
        for (const id of purgedIds) {
          ThumbStore.deleteThumb(context, id);
        }
        this.deps.refreshTrashEntries();
      })
      .catch((err: BusinessError): void => {
        console.error('TrashCoordinator purgeExpiredTrash failed');
      });
  }
}
