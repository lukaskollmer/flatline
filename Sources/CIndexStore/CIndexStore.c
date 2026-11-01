#include "CIndexStore.h"

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

static void write_error(char *error, size_t error_length, const char *message, const char *detail) {
  if (error == NULL || error_length == 0) {
    return;
  }
  snprintf(error, error_length, "%s%s%s", message, detail ? ": " : "", detail ? detail : "");
}

void *flatline_indexstore_open(const char *path, flatline_indexstore_functions_t *functions,
                               char *error, size_t error_length) {
  void *handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL);
  if (handle == NULL) {
    write_error(error, error_length, "could not load libIndexStore", dlerror());
    return NULL;
  }

  memset(functions, 0, sizeof(*functions));

#define LOAD(field, symbol)                                                  \
  do {                                                                       \
    *(void **)(&functions->field) = dlsym(handle, "indexstore_" #symbol);    \
    if (functions->field == NULL) {                                          \
      write_error(error, error_length, "libIndexStore is missing symbol",    \
                  "indexstore_" #symbol);                                    \
      dlclose(handle);                                                       \
      return NULL;                                                           \
    }                                                                        \
  } while (0)

  LOAD(error_get_description, error_get_description);
  LOAD(error_dispose, error_dispose);
  LOAD(format_version, format_version);

  LOAD(store_create, store_create);
  LOAD(store_dispose, store_dispose);
  LOAD(store_units_apply_f, store_units_apply_f);

  LOAD(unit_reader_create, unit_reader_create);
  LOAD(unit_reader_dispose, unit_reader_dispose);
  LOAD(unit_reader_get_provider_identifier, unit_reader_get_provider_identifier);
  LOAD(unit_reader_get_modification_time, unit_reader_get_modification_time);
  LOAD(unit_reader_is_system_unit, unit_reader_is_system_unit);
  LOAD(unit_reader_is_module_unit, unit_reader_is_module_unit);
  LOAD(unit_reader_has_main_file, unit_reader_has_main_file);
  LOAD(unit_reader_get_main_file, unit_reader_get_main_file);
  LOAD(unit_reader_get_module_name, unit_reader_get_module_name);
  LOAD(unit_reader_get_working_dir, unit_reader_get_working_dir);
  LOAD(unit_reader_get_output_file, unit_reader_get_output_file);
  LOAD(unit_reader_get_target, unit_reader_get_target);
  LOAD(unit_reader_dependencies_apply_f, unit_reader_dependencies_apply_f);

  LOAD(unit_dependency_get_kind, unit_dependency_get_kind);
  LOAD(unit_dependency_is_system, unit_dependency_is_system);
  LOAD(unit_dependency_get_filepath, unit_dependency_get_filepath);
  LOAD(unit_dependency_get_modulename, unit_dependency_get_modulename);
  LOAD(unit_dependency_get_name, unit_dependency_get_name);

  LOAD(record_reader_create, record_reader_create);
  LOAD(record_reader_dispose, record_reader_dispose);
  LOAD(record_reader_occurrences_apply_f, record_reader_occurrences_apply_f);

  LOAD(symbol_get_language, symbol_get_language);
  LOAD(symbol_get_kind, symbol_get_kind);
  LOAD(symbol_get_subkind, symbol_get_subkind);
  LOAD(symbol_get_properties, symbol_get_properties);
  LOAD(symbol_get_name, symbol_get_name);
  LOAD(symbol_get_usr, symbol_get_usr);

  LOAD(symbol_relation_get_roles, symbol_relation_get_roles);
  LOAD(symbol_relation_get_symbol, symbol_relation_get_symbol);

  LOAD(occurrence_get_symbol, occurrence_get_symbol);
  LOAD(occurrence_relations_apply_f, occurrence_relations_apply_f);
  LOAD(occurrence_get_roles, occurrence_get_roles);
  LOAD(occurrence_get_line_col, occurrence_get_line_col);

#undef LOAD

  return handle;
}

void flatline_indexstore_close(void *handle) {
  if (handle != NULL) {
    dlclose(handle);
  }
}
