/**
 * 分组选择弹窗（@CustomDialog）：单选列表（不分组 + 现有分组）+ 新建分组输入。
 * 用于导入时选组与单卡「移动到分组」；确定回调返回所选分组名（'' = 未分组，
 * 输入了新名称则优先返回新名称）。
 */
@CustomDialog
export struct GroupPickerDialog {
  controller?: CustomDialogController;
  groups: Array<string> = [];
  initialGroup: string = '';
  confirm: (group: string) => void = (group: string) => {
  };
  @State selected: string = '';
  @State newGroupName: string = '';

  aboutToAppear(): void {
    this.selected = this.initialGroup;
  }

  build() {
    Column({ space: 16 }) {
      Text($r('app.string.group_picker_title'))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      Scroll() {
        Column() {
          this.GroupRadio('', $r('app.string.group_ungrouped'))
          ForEach(this.groups, (group: string) => {
            this.GroupRadio(group, group)
          }, (group: string) => group)
        }
        .width('100%')
      }
      .constraintSize({ maxHeight: 260 })
      .width('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Auto)

      TextInput({ placeholder: $r('app.string.group_new_hint'), text: this.newGroupName })
        .width('100%')
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .backgroundColor($r('app.color.chip_bg'))
        .onChange((value: string) => {
          this.newGroupName = value;
          if (value.trim().length > 0) {
            this.selected = '';
          }
        })

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
            const typed = this.newGroupName.trim();
            const chosen = typed.length > 0 ? typed : this.selected;
            this.controller?.close();
            this.confirm(chosen);
          })
      }
      .width('100%')
    }
    .padding(20)
    .width('90%')
    .backgroundColor($r('app.color.panel_bg'))
    .borderRadius(16)
  }

  @Builder
  GroupRadio(value: string, label: ResourceStr) {
    Row({ space: 10 }) {
      Radio({ value: value, group: 'groupPickerGroup' })
        .checked(this.selected === value)
        .width(20)
        .height(20)
        .onChange((checked: boolean) => {
          if (checked) {
            this.selected = value;
            this.newGroupName = '';
          }
        })
      Text(label)
        .fontSize(14)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .onClick(() => {
      this.selected = value;
      this.newGroupName = '';
    })
  }
}
