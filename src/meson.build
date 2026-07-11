app_sources = files(
  'main.vala',
  'application.vala',
  'windows/dialog_window.vala',
  'windows/main_window.vala',
  'windows/preferences_window.vala',
  'windows/drop_window.vala',
  'windows/details_window.vala',
  'utils/ui_utils.vala'
)

app_resources = gnome.compile_resources('app-manager-resources',
  join_paths(meson.project_source_root(), 'data', 'resources', 'app-manager.gresource.xml'),
  source_dir: join_paths(meson.project_source_root(), 'data', 'resources'),
  c_name: 'app_manager'
)

executable('app-manager',
  core_sources + app_sources + app_resources,
  dependencies: [adw_dep, gtk_dep, gio_dep, gio_unix_dep, glib_dep, gmodule_dep, json_glib_dep, gee_dep, libsoup_dep, libsecret_dep],
  link_with: crypto_shim_lib,
  include_directories: crypto_shim_inc,
  install: true
)
