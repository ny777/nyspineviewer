/**
 * 删除分组确认弹窗（@CustomDialog，对齐安卓 DeleteGroupDialog）：
 * 「仅删分组」（组内模型移入未分组）/「删除组及全部模型」（破坏性，红色）/ 取消。
 */
@CustomDialog
export struct GroupDeleteDialog {
  controller?: CustomDialogController;
  groupName: string = '';
  confirm: (deleteModels: boolean) => void = (deleteModels: boolean) => {
  };

  build() {
    Column({ space: 16 }) {
      Text($r('app.string.delete_group_title'))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      Text($r('app.string.delete_group_msg', this.groupName))
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')

      Button($r('app.string.btn_delete_group_only'))
        .width('100%')
        .backgroundColor($r('app.color.chip_bg'))
        .fontColor($r('app.color.text_primary'))
        .onClick(() => {
          this.controller?.close();
          this.confirm(false);
        })

      Button($r('app.string.btn_delete_group_all'))
        .width('100%')
        .backgroundColor($r('app.color.chip_bg'))
        .fontColor($r('app.color.danger'))
        .onClick(() => {
          this.controller?.close();
          this.confirm(true);
        })

      Button($r('app.string.dialog_cancel'))
        .width('100%')
        .backgroundColor($r('app.color.chip_bg'))
        .fontColor($r('app.color.text_secondary'))
        .onClick(() => {
          this.controller?.close();
        })
    }
    .padding(20)
    .width('90%')
    .backgroundColor($r('app.color.panel_bg'))
    .borderRadius(16)
  }
}
