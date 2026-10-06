# ios app

[![Husk Downloads](https://img.shields.io/github/downloads/leviidev/husk/total?style=for-the-badge&color=5865F2&labelColor=111111)](https://github.com/leviidev/husk/releases)

واجهة iPhone جديدة لتشغيل تطبيقات أندرويد، مبنية على مشروع Husk.

هذه الحزمة تحتوي **المصدر المعدّل، وليست IPA مبنية أو موقّعة**.
راجع [تقرير التعديلات والفحص](SECURITY-AND-CHANGES-AR.txt) و[خطوات البناء والتجربة](BUILD-AND-TEST-AR.txt).

Drop in an APK, tap it, and the Android app opens full-screen.

## Builds

شغّل GitHub Actions يدويًا من `Actions > build-ipa > Run workflow`.
الملف الناتج، عند نجاح البناء، اسمه `ios-app-unsigned.ipa` داخل artifact
باسم `ios-app-ipa`. يحتاج توقيعًا وأداة JIT مناسبة للجهاز.
المشروع الداخلي واسم target بقيَا `Husk` لتجنب كسر الربط؛ الاسم الظاهر للمستخدم هو `ios app`.

## Licence

GPL-2.0-or-later. Husk links QEMU, which is GPLv2, so the shipped binary is a
combined GPLv2 work and the full source is public. It cannot go on the App
Store — both because of that and because it needs `get-task-allow` plus a
debugger attaching at runtime. See [docs/01-licensing.md](docs/01-licensing.md).
