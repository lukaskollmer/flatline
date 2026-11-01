// Types and function table for the index store C API (libIndexStore).
//
// The type declarations mirror clang's indexstore/indexstore.h, which is part
// of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
// Rather than linking against libIndexStore, flatline loads it at runtime
// with dlopen, so one binary works with whichever toolchain built the index.
// Only the non-block (`_f`) variants are used, since blocks are not available
// on Linux.

#ifndef FLATLINE_CINDEXSTORE_H
#define FLATLINE_CINDEXSTORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void *indexstore_error_t;
typedef void *indexstore_t;
typedef void *indexstore_unit_reader_t;
typedef void *indexstore_unit_dependency_t;
typedef void *indexstore_record_reader_t;
typedef void *indexstore_symbol_t;
typedef void *indexstore_symbol_relation_t;
typedef void *indexstore_occurrence_t;

typedef struct {
  const char *data;
  size_t length;
} indexstore_string_ref_t;

// The C API declares these as enums; their values fit in 32 bits.
typedef uint32_t indexstore_symbol_kind_t;
typedef uint32_t indexstore_symbol_subkind_t;
typedef uint32_t indexstore_symbol_language_t;
typedef uint32_t indexstore_unit_dependency_kind_t;
typedef uint64_t indexstore_symbol_property_t;
typedef uint64_t indexstore_symbol_role_t;

typedef struct {
  const char *(*error_get_description)(indexstore_error_t);
  void (*error_dispose)(indexstore_error_t);

  unsigned (*format_version)(void);

  indexstore_t (*store_create)(const char *store_path, indexstore_error_t *error);
  void (*store_dispose)(indexstore_t);
  bool (*store_units_apply_f)(indexstore_t, unsigned sorted, void *context,
                              bool (*applier)(void *context, indexstore_string_ref_t unit_name));

  indexstore_unit_reader_t (*unit_reader_create)(indexstore_t store, const char *unit_name,
                                                 indexstore_error_t *error);
  void (*unit_reader_dispose)(indexstore_unit_reader_t);
  indexstore_string_ref_t (*unit_reader_get_provider_identifier)(indexstore_unit_reader_t);
  void (*unit_reader_get_modification_time)(indexstore_unit_reader_t, int64_t *seconds,
                                            int64_t *nanoseconds);
  bool (*unit_reader_is_system_unit)(indexstore_unit_reader_t);
  bool (*unit_reader_is_module_unit)(indexstore_unit_reader_t);
  bool (*unit_reader_has_main_file)(indexstore_unit_reader_t);
  indexstore_string_ref_t (*unit_reader_get_main_file)(indexstore_unit_reader_t);
  indexstore_string_ref_t (*unit_reader_get_module_name)(indexstore_unit_reader_t);
  indexstore_string_ref_t (*unit_reader_get_working_dir)(indexstore_unit_reader_t);
  indexstore_string_ref_t (*unit_reader_get_output_file)(indexstore_unit_reader_t);
  indexstore_string_ref_t (*unit_reader_get_target)(indexstore_unit_reader_t);
  bool (*unit_reader_dependencies_apply_f)(indexstore_unit_reader_t, void *context,
                                           bool (*applier)(void *context, indexstore_unit_dependency_t));

  indexstore_unit_dependency_kind_t (*unit_dependency_get_kind)(indexstore_unit_dependency_t);
  bool (*unit_dependency_is_system)(indexstore_unit_dependency_t);
  indexstore_string_ref_t (*unit_dependency_get_filepath)(indexstore_unit_dependency_t);
  indexstore_string_ref_t (*unit_dependency_get_modulename)(indexstore_unit_dependency_t);
  indexstore_string_ref_t (*unit_dependency_get_name)(indexstore_unit_dependency_t);

  indexstore_record_reader_t (*record_reader_create)(indexstore_t store, const char *record_name,
                                                     indexstore_error_t *error);
  void (*record_reader_dispose)(indexstore_record_reader_t);
  bool (*record_reader_occurrences_apply_f)(indexstore_record_reader_t, void *context,
                                            bool (*applier)(void *context, indexstore_occurrence_t));

  indexstore_symbol_language_t (*symbol_get_language)(indexstore_symbol_t);
  indexstore_symbol_kind_t (*symbol_get_kind)(indexstore_symbol_t);
  indexstore_symbol_subkind_t (*symbol_get_subkind)(indexstore_symbol_t);
  indexstore_symbol_property_t (*symbol_get_properties)(indexstore_symbol_t);
  indexstore_string_ref_t (*symbol_get_name)(indexstore_symbol_t);
  indexstore_string_ref_t (*symbol_get_usr)(indexstore_symbol_t);

  indexstore_symbol_role_t (*symbol_relation_get_roles)(indexstore_symbol_relation_t);
  indexstore_symbol_t (*symbol_relation_get_symbol)(indexstore_symbol_relation_t);

  indexstore_symbol_t (*occurrence_get_symbol)(indexstore_occurrence_t);
  bool (*occurrence_relations_apply_f)(indexstore_occurrence_t, void *context,
                                       bool (*applier)(void *context, indexstore_symbol_relation_t));
  indexstore_symbol_role_t (*occurrence_get_roles)(indexstore_occurrence_t);
  void (*occurrence_get_line_col)(indexstore_occurrence_t, unsigned *line, unsigned *column);
} flatline_indexstore_functions_t;

/// Loads libIndexStore from `path` and fills `functions`.
///
/// Returns a handle to pass to `flatline_indexstore_close`, or NULL on
/// failure, in which case a description is written to `error` (if non-NULL).
void *flatline_indexstore_open(const char *path, flatline_indexstore_functions_t *functions,
                               char *error, size_t error_length);

void flatline_indexstore_close(void *handle);

#ifdef __cplusplus
}
#endif

#endif
