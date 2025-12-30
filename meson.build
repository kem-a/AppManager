project('app-manager', ['vala', 'c'],
  version: '2.0.0-beta',
  meson_version: '>=0.64.0'
)

gnome = import('gnome')

adw_dep = dependency('libadwaita-1', version: '>=1.5')
gio_dep = dependency('gio-2.0')
gio_unix_dep = dependency('gio-unix-2.0')
glib_dep = dependency('glib-2.0')
gtk_dep = dependency('gtk4')
json_glib_dep = dependency('json-glib-1.0')
gee_dep = dependency('gee-0.8')
libsoup_dep = dependency('libsoup-3.0')
libportal_dep = dependency('libportal', version: '>= 0.6')
libportal_gtk_dep = dependency('libportal-gtk4', version: '>= 0.6')

add_project_arguments(['--target-glib=2.74', '--pkg=posix'], language: 'vala')

# DwarFS tools bundling (mirrors appimage-thumbnailer approach)
dwarfs_version = '0.14.1'
dwarfs_tools_dir = get_option('prefix') / get_option('libdir') / 'app-manager' / 'dwarfs'

host_cpu = host_machine.cpu_family()
dwarfs_arch_map = {
  'x86_64': 'x86_64',
  'aarch64': 'aarch64',
  'arm': 'arm',
  'x86': 'i386',
  'ppc64': 'ppc64',
  'ppc64le': 'ppc64le',
  'riscv64': 'riscv64',
  's390x': 's390x',
}

dwarfs_arch = dwarfs_arch_map.get(host_cpu, '')
bundle_dwarfs = get_option('bundle_dwarfs')

core_sources = files(
  'src/core/app_constants.vala',
  'src/core/app_paths.vala',
  'src/core/installation_record.vala',
  'src/core/installation_registry.vala',
  'src/core/directory_monitor.vala',
  'src/core/app_image_metadata.vala',
  'src/core/app_image_assets.vala',
  'src/core/desktop_entry.vala',
  'src/core/installer.vala',
  'src/core/update_sources.vala',
  'src/core/updater.vala',
  'src/core/background_update_service.vala',
  'src/core/i18n.vala',
  'src/core/version_utils.vala',
  'src/utils/file_utils.vala'
)

build_info_conf = configuration_data()
build_info_conf.set('VERSION', meson.project_version())
build_info_conf.set('DWARFS_BUNDLE_DIR', dwarfs_tools_dir)
build_info = configure_file(
  input: 'src/core/build_info.vala.in',
  output: 'build_info.vala',
  configuration: build_info_conf
)

core_sources += build_info

# Fetch and install DwarFS tools if requested and supported
if bundle_dwarfs and dwarfs_arch != ''
  fetch_script = files('scripts/fetch-dwarfs-tools.sh')
  dwarfs_tools = custom_target('dwarfs-tools',
    output: ['dwarfsextract', 'dwarfsck'],
    build_by_default: bundle_dwarfs,
    command: ['sh', fetch_script, dwarfs_version, dwarfs_arch, meson.current_build_dir()],
    install: true,
    install_dir: dwarfs_tools_dir
  )
elif bundle_dwarfs and dwarfs_arch == ''
  warning('DwarFS tools bundling requested but architecture "@0@" is not supported'.format(host_cpu))
endif

subdir('data')
subdir('src')
