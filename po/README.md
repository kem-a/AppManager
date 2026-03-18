# Translating AppManager

## How to Contribute Translations

1. **Edit an existing translation**: Find the relevant `.po` file for your language and submit a PR with your improvements.
2. **Add a new language**: Use `app-manager.pot` as a template, save it as `po/xx.po` (where `xx` is your language code), translate the strings, and create a PR.

## Translation Status

| Language | Code | Status |
| -------- | ---- | ------ |
| Arabic | ar | 94.2% (261/277) |
| German | de | 94.2% (261/277) |
| Greek | el | 94.2% (261/277) |
| Spanish | es | 94.2% (261/277) |
| Estonian | et | 94.2% (261/277) |
| Finnish | fi | 94.2% (261/277) |
| French | fr | 100% (277/277) |
| Irish | ga | 100% (277/277) |
| Italian | it | 94.2% (261/277) |
| Japanese | ja | 94.2% (261/277) |
| Kazakh | kk | 94.2% (261/277) |
| Korean | ko | 94.2% (261/277) |
| Lithuanian | lt | 94.2% (261/277) |
| Latvian | lv | 100% (277/277) |
| Norwegian Bokmål | nb | 94.2% (261/277) |
| Dutch | nl | 94.2% (261/277) |
| Polish | pl | 94.2% (261/277) |
| Portuguese (Brazil) | pt_BR | 94.2% (261/277) |
| Swedish | sv | 94.2% (261/277) |
| Ukrainian | uk | 96.4% (267/277) |
| Vietnamese | vi | 94.2% (261/277) |
| Chinese (Simplified) | zh_CN | 94.2% (261/277) |

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
