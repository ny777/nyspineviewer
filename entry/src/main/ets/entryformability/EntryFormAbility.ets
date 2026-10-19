/**
 * 桌面卡片 FormExtensionAbility：
 * onAddForm 登记 formId 并返回快照数据（fd 不关：卡片进程 10 秒退出由系统回收）；
 * onRemoveForm 移除登记；refresh 消息重推已有快照。
 */
import { formBindingData, FormExtensionAbility, formInfo } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { WidgetFormsStore, WidgetUpdater } from '../widget/WidgetStore';

const TAG = 'EntryFormAbility';

export default class EntryFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    let formId = '';
    const params = want.parameters;
    if (params !== undefined && params !== null) {
      const idVal = params[formInfo.FormParam.IDENTITY_KEY];
      if (typeof idVal === 'string') {
        formId = idVal;
      }
    }
    if (formId.length > 0) {
      WidgetFormsStore.addForm(this.context, formId);
    }
    console.info(`${TAG} onAddForm formId=${formId}`);
    return WidgetUpdater.buildSnapshotData(this.context).formData;
  }

  onUpdateForm(formId: string): void {
    WidgetUpdater.updateFormById(this.context, formId).catch((err: Error) => {
      console.error(`${TAG} onUpdateForm failed: ${err.message}`);
    });
  }

  onFormEvent(formId: string, message: string): void {
    if (message === 'refresh') {
      WidgetUpdater.updateFormById(this.context, formId).catch((err: Error) => {
        console.error(`${TAG} onFormEvent refresh failed: ${err.message}`);
      });
    }
  }

  onRemoveForm(formId: string): void {
    console.info(`${TAG} onRemoveForm formId=${formId}`);
    WidgetFormsStore.removeForm(this.context, formId);
  }
}
