# دعم العربية العامية (خليجي)

اسم التطبيق يبقى **Husk** في كل اللغات (ما يتترجم).

## الملفات
- `ar.lproj/Localizable.strings` — واجهة بالعامية الخليجية
- `ar.lproj/InfoPlist.strings` — اسم العرض: Husk
- `en.lproj/...` — الإنجليزية
- `HuskL10n.swift` — مساعد `L("Key")` للنصوص البرمجية
- `Info.plist` — فيه `CFBundleLocalizations = en, ar`

## كيف يشتغل
1. انسخ `ar.lproj` و `en.lproj` لمجلد التطبيق في Xcode (جنب باقي الموارد).
2. أضف `HuskL10n.swift` للـ target.
3. استبدل `Info.plist` أو انقل مفتاح `CFBundleLocalizations` يدوياً.
4. على الآيفون: **الإعدادات → عام → اللغة والمنطقة → العربية**.
5. SwiftUI `Text("Library")` يترجم تلقائياً إذا المفتاح موجود في Localizable.strings.

## أمثلة عامية
| إنجليزي | عامية |
|---------|--------|
| Library | المكتبة |
| Settings | الإعدادات |
| JIT is off | الـ JIT مقفّل |
| Turn On | شغّل |
| Not Now | مو الحين |
| Download | حمّل |
| Crash Report | تقرير تعطل |
| Try Again | حاول مرة ثانية |

## ملاحظة
النصوص اللي فيها متغيرات (`Text("You have \(x)")`) ما تترجم تلقائي؛ حوّلها لـ `Text(L("…"))` أو `String(localized:)` مع format عند الحاجة.
