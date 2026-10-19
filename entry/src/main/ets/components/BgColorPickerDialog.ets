/**
 * 背景色选择弹窗（@CustomDialog）：预设色板 + 确定/取消。
 */

const BG_COLOR_PALETTE: Array<string> = [
  '#0F172A', '#0B1120', '#000000', '#1E293B',
  '#312E81', '#4C1D95', '#0C4A6E', '#065F46',
  '#7F1D1D', '#9D174D', '#FFFFFF', '#E2E8F0'
];

@CustomDialog
export struct BgColorPickerDialog {
  controller?: CustomDialogController;
  pickedColor: string = '#0F172A';
  /** 是否已设置自定义背景图（决定是否显示「移除背景图」）。 */
  hasBgImage: boolean = false;
  confirm: (color: string) => void = (color: string) => {
  };
  pickImage: () => void = () => {
  };
  removeImage: () => void = () => {
  };
  @State selectedColor: string = '#0F172A';

  aboutToAppear(): void {
    this.selectedColor = this.pickedColor;
  }

  build() {
    Column({ space: 16 }) {
      Text($r('app.string.color_title'))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
        ForEach(BG_COLOR_PALETTE, (color: string) => {
          Stack() {
            Column()
              .width(36)
              .height(36)
              .borderRadius(18)
              .backgroundColor(color)
            if (this.selectedColor === color) {
              Column()
                .width(40)
                .height(40)
                .borderRadius(20)
                .border({ width: 2, color: $r('app.color.primary') })
            }
          }
          .margin(6)
          .onClick(() => {
            this.selectedColor = color;
          })
        }, (color: string) => color)
      }
      .width('100%')

      // 背景图操作区：颜色与图片共存（图覆盖色，移除回色），与安卓一致
      Divider()
        .color($r('app.color.divider'))
        .width('100%')

      Button($r('app.string.btn_select_bg_image'))
        .width('100%')
        .backgroundColor($r('app.color.chip_bg'))
        .fontColor($r('app.color.text_primary'))
        .onClick(() => {
          this.controller?.close();
          this.pickImage();
        })

      if (this.hasBgImage) {
        Button($r('app.string.btn_remove_bg_image'))
          .width('100%')
          .backgroundColor($r('app.color.chip_bg'))
          .fontColor($r('app.color.danger'))
          .onClick(() => {
            this.controller?.close();
            this.removeImage();
          })
      }

      Row({ space: 12 }) {
        Button($r('app.string.dialog_cancel'))
          .layoutWeight(1)
          .backgroundColor($r('app.color.chip_bg'))
          .fontColor($r('app.color.text_secondary'))
          .onClick(() => {
            this.controller?.close();
          })
        Button($r('app.string.dialog_ok'))
          .layoutWeight(1)
          .backgroundColor($r('app.color.primary'))
          .fontColor(Color.White)
          .onClick(() => {
            const color = this.selectedColor;
            this.controller?.close();
            this.confirm(color);
          })
      }
      .width('100%')
    }
    .padding(20)
    .width('90%')
    .backgroundColor($r('app.color.panel_bg'))
    .borderRadius(16)
  }
}
