/**
 * 版本说明弹窗（功能 5）：可播放版本 / 可检测版本 / ZIP 结构建议 / 数据与许可提示。
 */
import { getTheme, ThemeColors } from '../core/Theme';

@CustomDialog
export struct VersionInfoDialog {
  controller?: CustomDialogController;
  @StorageProp('themeDark') themeDark: boolean = true;

  private theme(): ThemeColors {
    return getTheme(this.themeDark);
  }

  build() {
    Column({ space: 14 }) {
      Text($r('app.string.version_info_title'))
        .fontSize(17)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.theme().text)
        .width('100%')

      Scroll() {
        Column({ space: 12 }) {
          Column({ space: 4 }) {
            Text($r('app.string.version_playable_label'))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.theme().textSecondary)
              .width('100%')
            Text($r('app.string.version_playable_value'))
              .fontSize(13)
              .fontColor(this.theme().text)
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(12)
          .borderRadius(10)
          .backgroundColor(this.theme().card)

          Column({ space: 4 }) {
            Text($r('app.string.version_detectable_label'))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.theme().textSecondary)
              .width('100%')
            Text($r('app.string.version_detectable_value'))
              .fontSize(13)
              .fontColor(this.theme().text)
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(12)
          .borderRadius(10)
          .backgroundColor(this.theme().card)

          Column({ space: 4 }) {
            Text($r('app.string.version_zip_hint_title'))
              .fontSize(13)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.theme().textSecondary)
              .width('100%')
            Text($r('app.string.version_zip_hint_value'))
              .fontSize(13)
              .fontColor(this.theme().text)
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(12)
          .borderRadius(10)
          .backgroundColor(this.theme().card)

          Text($r('app.string.version_note'))
            .fontSize(12)
            .fontColor(this.theme().textMuted)
            .width('100%')
        }
        .width('100%')
      }
      .align(Alignment.Top)
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .width('100%')

      Button($r('app.string.btn_close'))
        .width('100%')
        .height(40)
        .fontSize(14)
        .backgroundColor(this.theme().accent)
        .fontColor(Color.White)
        .onClick(() => {
          this.controller?.close();
        })
    }
    .padding(18)
    .width('92%')
    .height(520)
    .borderRadius(16)
    .backgroundColor(this.theme().dialogBg)
  }
}
