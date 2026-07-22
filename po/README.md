# Translating AppManager

## Dependencies

Install the required tools before working with translations:

```bash
# Debian / Ubuntu
sudo apt install gettext itstool python3

# Fedora
sudo dnf install gettext itstool python3
```

## Quick Start — Using the Translation Script

The script at `scripts/translations.sh` helps you add or update translations
without needing to touch `.po` files directly.

### 1. Export untranslated strings

This generates a YAML file with all strings that still need translating:

```bash
./scripts/translations.sh --export lv      # → po/lv.yaml
```

### 2. Translate

Open the generated YAML file and fill in the `msgstr` fields:

```yaml
entries:
  - msgid: "Keep Both"
    msgstr: "Paturēt abus"
    locations: "src/application.vala:508, src/windows/drop_window.vala:460"
  - msgid: "Ignore"
    msgstr: "Ignorēt"
    locations: "src/application.vala:766"
```

### 3. Import translations

This validates the `.po` file, merges your translations, and validates again:

```bash
./scripts/translations.sh --import lv      # reads po/lv.yaml → po/lv.po
```

### 4. Submit

Commit your updated `.po` file and open a pull request.

> **Tip:** If the script reports errors during import, run `./scripts/translations.sh --fix`
> first to automatically mark broken entries as fuzzy, then try importing again.

### Adding a new language

To start a translation for a language that doesn't exist yet:

1. Add the language code to `po/LINGUAS` (e.g. `ru`)
2. Run `./scripts/translations.sh` — it will create the new `.po` from the template
3. Then use `--export` / `--import` as described above

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
