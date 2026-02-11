# Translating AppManager

## How to Contribute Translations

1. **Edit an existing translation**: Find the relevant `.po` file for your language and submit a PR with your improvements.
2. **Add a new language**: Use `app-manager.pot` as a template, save it as `po/xx.po` (where `xx` is your language code), translate the strings, and create a PR.

## Translation Status

| Language | Code | Status |
| -------- | ---- | ------ |
| German | de | 73% |
| Spanish | es | 88% |
| Estonian | et | 73% |
| Finnish | fi | 73% |
| French | fr | 73% |
| Italian | it | 73% |
| Japanese | ja | 73% |
| Lithuanian | lt | 73% |
| Latvian | lv | 73% |
| Norwegian Bokmål | nb | 73% |
| Dutch | nl | 100% |
| Portuguese (Brazil) | pt_BR | 73% |
| Swedish | sv | 73% |
| Chinese (Simplified) | zh_CN | 73% |

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
