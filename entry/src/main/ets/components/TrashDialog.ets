/**
 * 回收站弹窗（@CustomDialog）：已删模型列表（名称/版本/删除日期），
 * 单条恢复/彻底删除（确认）、清空回收站（确认）、关闭。
 * entries 由父组件持有 @State 并在每次操作后整体重赋值刷新。
 */
import { TrashEntry } from '../model/SpineModelLibrary';
import { getTheme, ThemeColors } from '../core/Theme';

/** 时间戳 → YYYY-MM-DD（本地时区，手动拼接避免 toLocale 差异）。 */
function formatDeletedDate(ts: number): string {
  const date = new Date(ts);
  const year = date.getFullYear();
  const month = date.getMonth() + 1;
  const day = date.getDate();
  const pad = (n: number): string => n < 10 ? `0${n}` : `${n}`;
  return `${year}-${pad(month)}-${pad(day)}`;
}

@CustomDialog
export struct TrashDialog {
  controller?: CustomDialogController;
  @Link entries: Array<TrashEntry>;
  onRestore: (modelId: string) => void = (modelId: string) => {
  };
  onPurge: (modelId: string) => void = (modelId: string) => {
  };
  onEmpty: () => void = () => {
  };
  @StorageProp('themeDark') themeDark: boolean = true;

  private theme(): ThemeColors {
    return getTheme(this.themeDark);
  }

  build() {
    Column({ space: 14 }) {
      Row({ space: 8 }) {
        Text($r('app.string.trash_title'))
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.theme().text)
          .layoutWeight(1)
        Text(`${this.entries.length}`)
          .fontSize(11)
          .fontColor(this.theme().badgeText)
          .backgroundColor(this.theme().badgeBg)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(8)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (this.entries.length === 0) {
        Text($r('app.string.trash_empty_text'))
          .fontSize(14)
          .fontColor(this.theme().textMuted)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 24, bottom: 24 })
      } else {
        List({ space: 8 }) {
          ForEach(this.entries, (entry: TrashEntry) => {
            ListItem() {
              Row({ space: 10 }) {
                Column({ space: 4 }) {
                  Text(entry.model.name)
                    .fontSize(14)
                    .fontColor(this.theme().text)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Row({ space: 6 }) {
                    Text(entry.model.version)
                      .fontSize(10)
                      .fontColor(this.theme().badgeText)
                      .backgroundColor(this.theme().badgeBg)
                      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                      .borderRadius(4)
                    Text($r('app.string.trash_deleted_at', formatDeletedDate(entry.deletedAt)))
                      .fontSize(10)
                      .fontColor(this.theme().textMuted)
                      .maxLines(1)
                  }
                  .alignItems(VerticalAlign.Center)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Button($r('app.string.trash_restore'))
                  .fontSize(12)
                  .height(28)
                  .padding({ left: 12, right: 12 })
                  .backgroundColor(this.theme().importBtn)
                  .fontColor(Color.White)
                  .onClick(() => {
                    this.onRestore(entry.model.id);
                  })
                Button($r('app.string.trash_purge'))
                  .fontSize(12)
                  .height(28)
                  .padding({ left: 12, right: 12 })
                  .backgroundColor(this.theme().chip)
                  .fontColor(this.theme().danger)
                  .onClick(() => {
                    this.getUIContext().showAlertDialog({
                      message: $r('app.string.trash_purge_confirm'),
                      primaryButton: {
                        value: $r('app.string.dialog_cancel'),
                        action: (): void => {
                        }
                      },
                      secondaryButton: {
                        value: $r('app.string.dialog_delete'),
                        fontColor: this.theme().danger,
                        action: (): void => {
                          this.onPurge(entry.model.id);
                        }
                      }
                    });
                  })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding(10)
              .borderRadius(10)
              .backgroundColor(this.theme().card)
            }
          }, (entry: TrashEntry) => `${entry.model.id}::${entry.deletedAt}`)
        }
        .constraintSize({ maxHeight: 420 })
        .width('100%')
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      }

      Row({ space: 12 }) {
        Button($r('app.string.trash_empty_btn'))
          .layoutWeight(1)
          .backgroundColor(this.theme().chip)
          .fontColor(this.theme().danger)
          .fontSize(14)
          .enabled(this.entries.length > 0)
          .opacity(this.entries.length > 0 ? 1 : 0.5)
          .onClick(() => {
            this.getUIContext().showAlertDialog({
              message: $r('app.string.trash_empty_confirm'),
              primaryButton: {
                value: $r('app.string.dialog_cancel'),
                action: (): void => {
                }
              },
              secondaryButton: {
                value: $r('app.string.dialog_delete'),
                fontColor: this.theme().danger,
                action: (): void => {
                  this.onEmpty();
                }
              }
            });
          })
        Button($r('app.string.batch_done'))
          .layoutWeight(1)
          .backgroundColor(this.theme().accent)
          .fontColor(Color.White)
          .fontSize(14)
          .onClick(() => {
            this.controller?.close();
          })
      }
      .width('100%')
    }
    .padding(20)
    .width('90%')
    .backgroundColor(this.theme().dialogBg)
    .borderRadius(16)
  }
}
