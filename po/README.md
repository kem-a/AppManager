# Translating AppManager

## How to Contribute Translations

1. **Edit an existing translation**: Find the relevant `.po` file for your language and submit a PR with your improvements.
2. **Add a new language**: Use `app-manager.pot` as a template, save it as `po/xx.po` (where `xx` is your language code), translate the strings, and create a PR.

## Translation Status

| Language | Code | Status |
| -------- | ---- | ------ |
| Arabic | ar | 93.1% (298/320) |
| German | de | 93.1% (298/320) |
| Greek | el | 93.1% (298/320) |
| Spanish | es | 93.1% (298/320) |
| Estonian | et | 93.1% (298/320) |
| Finnish | fi | 93.1% (298/320) |
| French | fr | 93.4% (299/320) |
| Irish | ga | 93.4% (299/320) |
| Italian | it | 93.1% (298/320) |
| Japanese | ja | 93.1% (298/320) |
| Kazakh | kk | 93.1% (298/320) |
| Korean | ko | 93.1% (298/320) |
| Lithuanian | lt | 93.1% (298/320) |
| Latvian | lv | 96.6% (309/320) |
| Norwegian Bokmål | nb | 93.1% (298/320) |
| Dutch | nl | 93.1% (298/320) |
| Polish | pl | 100% (320/320) |
| Portuguese (Brazil) | pt_BR | 93.1% (298/320) |
| Swedish | sv | 93.1% (298/320) |
| Ukrainian | uk | 93.1% (298/320) |
| Vietnamese | vi | 93.1% (298/320) |
| Chinese (Simplified) | zh_CN | 93.1% (298/320) |

## Note

> Some translations are machine-generated and may contain mistakes. Native speakers are welcome to review and improve them!

## Testing Translations Locally

After building with meson, translations are compiled automatically. To test:

```bash
meson setup build --prefix=$HOME/.local
meson compile -C build
meson install -C build
```

Then run the app with a specific locale:

```bash
LANGUAGE=de app-manager
```

## Further Reading

- [GNU gettext Manual](https://www.gnu.org/software/gettext/manual/gettext.html)
- [Vala i18n documentation](https://wiki.gnome.org/Projects/Vala/TranslationSample)
