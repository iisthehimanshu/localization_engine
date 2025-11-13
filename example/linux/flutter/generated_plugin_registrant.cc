//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <localization_engine_core/localization_engine_core_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) localization_engine_core_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "LocalizationEngineCorePlugin");
  localization_engine_core_plugin_register_with_registrar(localization_engine_core_registrar);
}
