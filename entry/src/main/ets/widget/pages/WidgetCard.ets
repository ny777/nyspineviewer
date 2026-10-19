/**
 * 桌面静态快照卡片（2*2 / 2*4）：
 * 有快照时全幅显示模型截图，底部半透明标题条；无快照时显示占位提示。
 * 点击卡片通过 postCardAction router 拉起主应用 EntryAbility。
 */
let storage = new LocalStorage();

@Entry(storage)
@Component
struct WidgetCard {
  @LocalStorageProp('imgSrc') imgSrc: string = '';
  @LocalStorageProp('title') title: string = '';

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.imgSrc === '') {
        Column({ space: 8 }) {
          Text($r('app.string.widget_placeholder_title'))
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
          Text($r('app.string.widget_placeholder_hint'))
            .fontSize(12)
            .fontColor('#94A3B8')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#0F172A')
      } else {
        Image(this.imgSrc)
          .objectFit(ImageFit.Cover)
          .interpolation(ImageInterpolation.High)
          .width('100%')
          .height('100%')
      }
      if (this.title !== '') {
        Column() {
          Text(this.title)
            .fontSize(12)
            .fontColor('#FFFFFF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 6, bottom: 6 })
        .backgroundColor('rgba(15,23,42,0.55)')
      }
    }
    .onClick(() => {
      postCardAction(this, { 'action': 'router', 'abilityName': 'EntryAbility' });
    })
  }
}
