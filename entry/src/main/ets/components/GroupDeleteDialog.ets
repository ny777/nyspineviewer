/**
 * 删除分组确认弹窗（@CustomDialog，对齐安卓 DeleteGroupDialog）：
 * 「仅删分组」（组内模型移入未分组）/「删除组及全部模型」（破坏性，红色）/ 取消。
 */
import { getTheme, ThemeColors } from '../core/Theme';

@CustomDialog
export struct GroupDeleteDialog {
  controller?: CustomDialogController;
  groupName: string = '';
  confirm: (deleteModels: boolean) => void = (deleteModels: boolean) => {
  };
  @StorageProp('themeDark') themeDark: boolean = true;

  private theme(): ThemeColors {
    return getTheme(this.themeDark);
  }

  build() {
    Column({ space: 16 }) {
      Text($r('app.string.delete_group_title'))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.theme().text)
        .width('100%')

      Text($r('app.string.delete_group_msg', this.groupName))
        .fontSize(13)
        .fontColor(this.theme().textSecondary)
        .width('100%')

      Button($r('app.string.btn_delete_group_only'))
        .width('100%')
        .backgroundColor(this.theme().chip)
        .fontColor(this.theme().text)
        .onClick(() => {
          this.controller?.close();
          this.confirm(false);
        })

      Button($r('app.string.btn_delete_group_all'))
        .width('100%')
        .backgroundColor(this.theme().chip)
        .fontColor(this.theme().danger)
        .onClick(() => {
          this.controller?.close();
          this.confirm(true);
        })

      Button($r('app.string.dialog_cancel'))
        .width('100%')
        .backgroundColor(this.theme().chip)
        .fontColor(this.theme().textSecondary)
        .onClick(() => {
          this.controller?.close();
        })
    }
    .padding(20)
    .width('90%')
    .backgroundColor(this.theme().dialogBg)
    .borderRadius(16)
  }
}
