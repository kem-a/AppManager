project('app-manager', ['vala', 'c'],
  version: '0.1.0-alpha',
  meson_version: '>=0.64.0'
)

gnome = import('gnome')

adw_dep = dependency('libadwaita-1', version: '>=1.4')
gio_dep = dependency('gio-2.0')
gio_unix_dep = dependency('gio-unix-2.0')
glib_dep = dependency('glib-2.0')
gtk_dep = dependency('gtk4')
json_glib_dep = dependency('json-glib-1.0')
nautilus_dep = dependency('libnautilus-extension-4', required: false)
gee_dep = dependency('gee-0.8')

add_project_arguments(['--target-glib=2.74', '--pkg=posix'], language: 'vala')

core_sources = files(
  'src/core/app_constants.vala',
  'src/core/app_paths.vala',
  'src/core/installation_record.vala',
  'src/core/installation_registry.vala',
  'src/core/app_image_metadata.vala',
  'src/core/app_image_assets.vala',
  'src/core/installer.vala',
  'src/core/i18n.vala',
  'src/utils/file_utils.vala'
)

build_info_conf = configuration_data()
build_info_conf.set('VERSION', meson.project_version())
build_info = configure_file(
  input: 'src/core/build_info.vala.in',
  output: 'build_info.vala',
  configuration: build_info_conf
)

core_sources += build_info

subdir('data')
subdir('src')
if nautilus_dep.found()
  subdir('extensions')
endif
