//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <adapter_manager/adapter_manager_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) adapter_manager_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "AdapterManagerPlugin");
  adapter_manager_plugin_register_with_registrar(adapter_manager_registrar);
}
