# NonGPS Maps — Політика конфіденційності

*Набирає чинності 24 листопада 2026 року. English version below.*

NonGPS Maps — застосунок для офлайн-навігації автомобілем, зокрема коли GPS недоступний або показує
неправильне місце. Розробник: Ramzess (NonGPS Maps), контакт: most05062014@gmail.com.

## Коротко

- Ми **не збираємо** ваших даних. У застосунку немає реклами, аналітики, облікових записів і серверів
  розробника. Єдиний виняток — звіт про збій застосунку, який можна вимкнути в налаштуваннях.
- Ваше місцеположення обробляється **лише на телефоні** і нікуди не надсилається.
- Дані залишають телефон лише тоді, коли ви самі це робите (завантажуєте карти, надсилаєте звіт про
  помилку, редагуєте карту OpenStreetMap, ділитеся місцем) і коли застосунок аварійно завершується та
  надсилає звіт про збій.

## Які дані обробляє застосунок і навіщо

| Дані | Навіщо | Куди потрапляють |
|---|---|---|
| Точне й приблизне місцеположення (GPS, вишки, Wi-Fi) | Показати вас на карті, прокласти маршрут, розпізнати хибні позиції GPS | Лише на телефоні |
| Дані датчиків руху (гіроскоп, акселерометр) | Інерціальна навігація, коли немає GPS | Лише на телефоні |
| Швидкість автомобіля від адаптера OBD-II ELM327 (Bluetooth) | Розрахунок пройденої відстані | Лише на телефоні |
| Дані блоку датчиків ESP32 (Bluetooth) | Поворот і швидкість автомобіля | Лише на телефоні; блок не має доступу до інтернету |
| Журнал поїздки (якщо ви ввімкнули логування в налаштуваннях) | Розбір помилок навігації | Лише на телефоні, доки ви самі його не надішлете |
| Закладки, треки, маршрути, налаштування | Робота застосунку | Лише на телефоні |
| Звіт про збій (якщо застосунок аварійно завершився і перемикач «Надсилати звіти про збої» ввімкнений): стан програми в момент збою, умова перевірки, що не пройшла, модель телефона, версія застосунку й системи, назва екрана, стан блоку датчиків. Без координат, журналів, IP-адреси та скриншотів | Знайти й виправити збій | Sentry (sentry.io), сервери в ЄС |

Застосунок використовує служби визначення місцеположення Android. Позиції за вишками та Wi-Fi
обчислює сама система Android (на більшості телефонів — служби Google); це регулюється політикою
конфіденційності виробника телефону або Google, а не цим застосунком.

## Коли дані залишають телефон

- **Завантаження карт.** Карти завантажуються з серверів проєкту Organic Maps (organicmaps.app). Як і
  будь-який запит в інтернеті, сервер бачить IP-адресу телефона та назви карт, які завантажуються.
  Місцеположення не передається. Див. політику Organic Maps: https://organicmaps.app/privacy
- **Звіт про помилку.** Якщо ви натиснете «Повідомити про помилку», застосунок підготує лист у вашому
  поштовому застосунку з описом пристрою і журналом. Журнал поїздки містить координати. Лист буде
  надіслано лише після того, як ви самі його відправите, на адресу most05062014@gmail.com. Ми
  використовуємо його лише для виправлення помилки і видаляємо після цього.
- **Звіт про збій.** Коли застосунок аварійно завершується, під час наступного запуску він надсилає
  звіт до служби Sentry (sentry.io, оброблювач даних; дані зберігаються на серверах у ЄС, зазвичай 30
  днів). Звіт не містить координат, журналів поїздки, IP-адреси та скриншотів. Це можна вимкнути
  перемикачем «Надсилати звіти про збої» в налаштуваннях: після цього нічого не надсилається. У збірках
  для розробників звіти не надсилаються.
- **Редагування OpenStreetMap.** Якщо ви увійдете в обліковий запис OpenStreetMap і внесете правку,
  вона надсилається на openstreetmap.org та стає публічною за правилами OpenStreetMap.
- **«Поділитися».** Посилання на місце, яке ви надсилаєте іншим, містить його координати.

## Дозволи

- **Місцеположення** — показ на карті та навігація, у тому числі з вимкненим екраном під час
  навігації або запису треку (фонова служба). Доступ до місцеположення у фоні без активної навігації
  застосунок не запитує.
- **Пристрої поблизу (Bluetooth)** — з'єднання з адаптером OBD-II ELM327.
- **Сповіщення** — стан завантаження карт, навігації та запису треку.
- **Інтернет** — завантаження карт.

## Діти

Застосунок не призначений для дітей і свідомо не обробляє даних дітей.

## Зберігання та видалення

Усі дані зберігаються на телефоні. Щоб видалити їх, видаліть застосунок або очистіть його дані в
налаштуваннях Android. Так само видаляються журнали поїздок.

## Зміни

Про зміни цієї політики ми повідомимо оновленням цієї сторінки та в описі нової версії застосунку.

---

# NonGPS Maps — Privacy Policy

*Effective November 24, 2026.*

NonGPS Maps is an app for offline car navigation, also when GPS is unavailable or shows a wrong place.
Developer: Ramzess (NonGPS Maps), contact: most05062014@gmail.com.

## In short

- We **do not collect** your data. The app has no ads, no analytics, no accounts and no developer
  servers. The one exception is a crash report, which you can turn off in the settings.
- Your location is processed **on the phone only** and is never sent anywhere.
- Data leaves the phone only when you do it yourself (download maps, send a bug report, edit the
  OpenStreetMap map, share a place) and when the app crashes and sends a crash report.

## What the app processes and why

| Data | Why | Where it goes |
|---|---|---|
| Precise and approximate location (GPS, cell towers, Wi-Fi) | Show you on the map, build routes, detect wrong GPS positions | The phone only |
| Motion sensors (gyroscope, accelerometer) | Dead reckoning without GPS | The phone only |
| Car speed from an OBD-II ELM327 adapter (Bluetooth) | Distance driven | The phone only |
| ESP32 sensor box data (Bluetooth) | Car rotation and speed | The phone only; the box has no internet access |
| Trip log (if you turn logging on in the settings) | Investigating navigation errors | The phone only, until you send it yourself |
| Bookmarks, tracks, routes, settings | App features | The phone only |
| A crash report (if the app crashed and the "Send crash reports" switch is on): the state of the program at the crash, the failed check, phone model, app and system version, screen name, sensor box state. No coordinates, logs, IP address or screenshots | Finding and fixing the crash | Sentry (sentry.io), servers in the EU |

The app uses Android location services. Cell tower and Wi-Fi positions are computed by Android itself
(on most phones by Google services), which is governed by the privacy policy of your phone maker or
Google, not by this app.

## When data leaves the phone

- **Map downloads.** Maps are downloaded from the servers of the Organic Maps project
  (organicmaps.app). Like any internet request, the server sees the IP address of the phone and the
  names of the downloaded maps. Your location is not sent. See https://organicmaps.app/privacy
- **Bug reports.** If you tap "Report a bug", the app prepares an email in your email app with device
  information and the log. The trip log contains coordinates. It is sent to most05062014@gmail.com only
  when you send it yourself. We use it only to fix the bug and delete it afterwards.
- **Crash reports.** When the app crashes, it sends a report to Sentry (sentry.io, a data processor;
  the data is stored on servers in the EU, usually for 30 days) at the next launch. The report holds no
  coordinates, trip logs, IP address or screenshots. You can turn it off with the "Send crash reports"
  switch in the settings: nothing is sent then. Developer builds send no reports.
- **OpenStreetMap edits.** If you sign in to OpenStreetMap and make an edit, it is sent to
  openstreetmap.org and becomes public under the OpenStreetMap rules.
- **Sharing.** A link to a place you share contains its coordinates.

## Permissions

- **Location** — the map and navigation, also with the screen off while navigating or recording a track
  (a foreground service). The app doesn't request background location access without active navigation.
- **Nearby devices (Bluetooth)** — connection to the OBD-II ELM327 adapter.
- **Notifications** — status of map downloads, navigation and track recording.
- **Internet** — map downloads.

## Children

The app is not directed to children and does not knowingly process children's data.

## Storage and deletion

All data is stored on the phone. To delete it, uninstall the app or clear its data in the Android
settings. Trip logs are deleted the same way.

## Changes

Changes to this policy are published on this page and in the release notes of the app.
