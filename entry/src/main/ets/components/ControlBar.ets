/**
 * 底部播放控制条：槽位切换 / 播放暂停 / 截帧 / 重置变换 / 背景色 /
 * 动画菜单 / PMA / 帧率 / 皮肤多选。全部为受控组件，状态与持久化由父页面持有。
 */
@Component
export struct ControlBar {
  @Prop slot: number = 0;
  @Prop playing: boolean = true;
  @Prop capturing: boolean = false;
  @Prop animations: Array<string> = [];
  @Prop currentAnimation: string = '';
  @Prop skins: Array<string> = [];
  @Prop selectedSkins: Array<string> = [];
  @Prop pma: boolean = true;
  @Prop fps: number = 60;

  onSlotChange: (slot: number) => void = (slot: number) => {
  };
  onTogglePlay: () => void = () => {
  };
  onAnimationPick: (name: string) => void = (name: string) => {
  };
  onSkinToggle: (name: string) => void = (name: string) => {
  };
  onPmaChange: (pma: boolean) => void = (pma: boolean) => {
  };
  onFpsChange: (fps: number) => void = (fps: number) => {
  };
  onCapture: () => void = () => {
  };
  onResetTransform: () => void = () => {
  };
  onPickBgColor: () => void = () => {
  };

  build() {
    Column({ space: 10 }) {
      // 行1：槽位 / 播放 / 截帧 / 重置变换 / 背景色
      Row({ space: 8 }) {
        Row() {
          Text($r('app.string.slot_main'))
            .fontSize(12)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(this.slot === 0 ? $r('app.color.primary') : $r('app.color.chip_bg'))
            .fontColor(this.slot === 0 ? Color.White : $r('app.color.text_secondary'))
            .borderRadius({ topLeft: 14, bottomLeft: 14 })
            .onClick(() => {
              this.onSlotChange(0);
            })
          Text($r('app.string.slot_sub'))
            .fontSize(12)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(this.slot === 1 ? $r('app.color.primary') : $r('app.color.chip_bg'))
            .fontColor(this.slot === 1 ? Color.White : $r('app.color.text_secondary'))
            .borderRadius({ topRight: 14, bottomRight: 14 })
            .onClick(() => {
              this.onSlotChange(1);
            })
        }
        .alignItems(VerticalAlign.Center)

        Button(this.playing ? $r('app.string.pause') : $r('app.string.play'))
          .fontSize(12)
          .height(30)
          .padding({ left: 10, right: 10 })
          .backgroundColor($r('app.color.chip_bg'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            this.onTogglePlay();
          })

        Button($r('app.string.capture'))
          .fontSize(12)
          .height(30)
          .padding({ left: 10, right: 10 })
          .backgroundColor($r('app.color.primary'))
          .fontColor(Color.White)
          .enabled(!this.capturing)
          .onClick(() => {
            this.onCapture();
          })

        Button($r('app.string.reset_transform'))
          .fontSize(12)
          .height(30)
          .padding({ left: 10, right: 10 })
          .backgroundColor($r('app.color.chip_bg'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            this.onResetTransform();
          })

        Button($r('app.string.bg_color'))
          .fontSize(12)
          .height(30)
          .padding({ left: 10, right: 10 })
          .backgroundColor($r('app.color.chip_bg'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            this.onPickBgColor();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 行2：动画 / PMA / 帧率
      Row({ space: 10 }) {
        Text($r('app.string.animation_label'))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
        Text(this.currentAnimation.length > 0 ? this.currentAnimation : $r('app.string.no_animation'))
          .fontSize(12)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 140 })
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .borderRadius(15)
          .backgroundColor($r('app.color.chip_bg'))
          .fontColor($r('app.color.text_primary'))
          .bindMenu(this.AnimationMenuBuilder)
        Row({ space: 6 }) {
          Text($r('app.string.pma_label'))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
          Toggle({ type: ToggleType.Switch, isOn: this.pma })
            .onChange((isOn: boolean) => {
              this.onPmaChange(isOn);
            })
        }
        .alignItems(VerticalAlign.Center)
        Row({ space: 6 }) {
          Text($r('app.string.fps_label'))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
          Slider({ value: this.fps, min: 15, max: 120, step: 1, style: SliderStyle.OutSet })
            .layoutWeight(1)
            .onChange((value: number, mode: SliderChangeMode) => {
              if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                this.onFpsChange(Math.round(value));
              }
            })
        }
        .alignItems(VerticalAlign.Center)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 行3：皮肤多选
      if (this.skins.length > 0) {
        Row({ space: 8 }) {
          Text($r('app.string.skins_label'))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
          Scroll() {
            Row({ space: 8 }) {
              ForEach(this.skins, (name: string) => {
                Text(name)
                  .fontSize(12)
                  .maxLines(1)
                  .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                  .borderRadius(13)
                  .backgroundColor(this.selectedSkins.includes(name) ? $r('app.color.primary') : $r('app.color.chip_bg'))
                  .fontColor(this.selectedSkins.includes(name) ? Color.White : $r('app.color.text_secondary'))
                  .onClick(() => {
                    this.onSkinToggle(name);
                  })
              }, (name: string) => name)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .layoutWeight(1)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
      }
    }
    .padding({ left: 16, right: 16, top: 12, bottom: 16 })
    .backgroundColor($r('app.color.bar_bg'))
    .width('100%')
  }

  @Builder
  AnimationMenuBuilder() {
    Menu() {
      ForEach(this.animations, (name: string) => {
        MenuItem({ content: name })
          .onClick(() => {
            this.onAnimationPick(name);
          })
      }, (name: string) => name)
    }
  }
}
