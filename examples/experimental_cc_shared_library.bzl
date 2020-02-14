"""This is an experimental implementation of cc_shared_library.

We may change the implementation at any moment or even delete this file. Do not
rely on this. It requires bazel >1.2  and passing the flag
--experimental_cc_shared_library
"""

load("//cc:find_cc_toolchain.bzl", "find_cc_toolchain")

# TODO(#5200): Add export_define to library_to_link and cc_library

GraphNodeInfo = provider(
    fields = {
        "children": "Other GraphNodeInfo from dependencies of this target",
        "label": "Label of the target visited",
    },
)
CcSharedLibraryInfo = provider(
    fields = {
        "dynamic_deps": "All shared libraries depended on transitively",
        "exports": "cc_libraries that are linked statically and exported",
        "linker_input": "the resulting linker input artifact for the shared library",
        "preloaded_deps": "cc_libraries needed by this cc_shared_library that should" +
                          " be linked the binary. If this is set, this cc_shared_library has to " +
                          " be a direct dependency of the cc_binary",
        "static_libs": "All libraries linked statically into this library",
    },
)

def _separate_static_and_dynamic_link_libraries(
        direct_children,
        can_be_linked_dynamically,
        preloaded_deps_direct_labels):
    node = None
    all_children = list(direct_children)
    link_statically_labels = {}
    link_dynamically_labels = {}

    # Horrible I know. Perhaps Starlark team gives me a way to prune a tree.
    for i in range(1, 2147483647):
        if len(all_children) == 0:
            break
        node = all_children.pop(0)

        node_label = str(node.label)
        if node_label in can_be_linked_dynamically:
            link_dynamically_labels[node_label] = True
        elif node_label not in preloaded_deps_direct_labels:
            link_statically_labels[node_label] = True
            all_children.extend(node.children)
    return (link_statically_labels, link_dynamically_labels)

def _create_linker_context(ctx, static_linker_inputs, dynamic_linker_inputs):
    linker_inputs = []

    # Statically linked symbols should take precedence over dynamically linked.
    linker_inputs.extend(static_linker_inputs)
    linker_inputs.extend(dynamic_linker_inputs)

    return cc_common.create_linking_context(
        linker_inputs = depset(linker_inputs, order = "topological"),
    )

def _merge_cc_shared_library_infos(ctx):
    dynamic_deps = []
    transitive_dynamic_deps = []
    for dep in ctx.attr.dynamic_deps:
        if dep[CcSharedLibraryInfo].preloaded_deps != None:
            fail("{} can only be a direct dependency of a " +
                 " cc_binary because it has " +
                 "preloaded_deps".format(str(dep.label)))
        dynamic_dep_entry = (
            dep[CcSharedLibraryInfo].exports,
            dep[CcSharedLibraryInfo].linker_input,
            dep[CcSharedLibraryInfo].static_libs,
        )
        dynamic_deps.append(dynamic_dep_entry)
        transitive_dynamic_deps.append(dep[CcSharedLibraryInfo].dynamic_deps)

    return depset(direct = dynamic_deps, transitive = transitive_dynamic_deps)

def _build_exports_map_from_only_dynamic_deps(merged_shared_library_infos):
    exports_map = {}
    for entry in merged_shared_library_infos.to_list():
        exports = entry[0]
        linker_input = entry[1]
        for export in exports:
            if export in exports_map:
                fail("Two shared libraries in dependencies export the same symbols. Both " +
                     exports_map[export].libraries[0].dynamic_library.short_path +
                     " and " + linker_input.dynamic_library.short_path +
                     " export " + export)
            exports_map[export] = linker_input
    return exports_map

def _build_static_libs_map(merged_shared_library_infos):
    static_libs_map = {}
    for entry in merged_shared_library_infos.to_list():
        static_libs = entry[2]
        linker_input = entry[1]
        for static_lib in static_libs:
            if static_lib in static_libs_map:
                fail("Two shared libraries in dependencies link the same " +
                     " library statically. Both " + static_libs_map[static_lib] +
                     " and " + str(linker_input.owner) +
                     " link statically" + static_lib)
            static_libs_map[static_lib] = str(linker_input.owner)
    return static_libs_map

def _wrap_static_library_with_alwayslink(ctx, feature_configuration, cc_toolchain, linker_input):
    new_libraries_to_link = []
    for old_library_to_link in linker_input.libraries:
        # TODO(#5200): This will lose the object files from a library to link.
        # Not too bad for the prototype but as soon as the library_to_link
        # constructor has object parameters this should be changed.
        new_library_to_link = cc_common.create_library_to_link(
            actions = ctx.actions,
            feature_configuration = feature_configuration,
            cc_toolchain = cc_toolchain,
            static_library = old_library_to_link.static_library,
            pic_static_library = old_library_to_link.pic_static_library,
            alwayslink = True,
        )
        new_libraries_to_link.append(new_library_to_link)

    return cc_common.create_linker_input(
        owner = linker_input.owner,
        libraries = depset(direct = new_libraries_to_link),
        user_link_flags = depset(direct = linker_input.user_link_flags),
        additional_inputs = depset(direct = linker_input.additional_inputs),
    )

def _check_if_target_under_path(path, target, target_specified):
    if not _same_package_or_above(path, target):
        return False
    if target_specified:
        return path.name == target.name
    return True

def _is_target_specified(path):
    if path.startswith("//") or path.startswith("@"):
        if path.find(":") != -1:
            return True
        else:
            return False
    else:
        return True

def _filter_inputs(
        ctx,
        feature_configuration,
        cc_toolchain,
        transitive_exports,
        preloaded_deps_direct_labels,
        static_libs_map):
    static_linker_inputs = []
    dynamic_linker_inputs = []

    graph_structure_aspect_nodes = []
    linker_inputs = []
    direct_exports = {}
    for export in ctx.attr.exports:
        direct_exports[str(export.label)] = True
        linker_inputs.extend(export[CcInfo].linking_context.linker_inputs.to_list())
        graph_structure_aspect_nodes.append(export[GraphNodeInfo])

    can_be_linked_dynamically = {}
    for linker_input in linker_inputs:
        owner = str(linker_input.owner)
        if owner in transitive_exports:
            can_be_linked_dynamically[owner] = True

    (link_statically_labels, link_dynamically_labels) = _separate_static_and_dynamic_link_libraries(
        graph_structure_aspect_nodes,
        can_be_linked_dynamically,
        preloaded_deps_direct_labels,
    )

    already_linked_dynamically = {}
    owners_seen = {}
    for linker_input in linker_inputs:
        owner = str(linker_input.owner)
        if owner in owners_seen:
            continue
        owners_seen[owner] = True
        if owner in link_dynamically_labels:
            dynamic_linker_input = transitive_exports[owner]
            if str(dynamic_linker_input.owner) not in already_linked_dynamically:
                already_linked_dynamically[str(dynamic_linker_input.owner)] = True
                dynamic_linker_inputs.append(dynamic_linker_input)
        elif owner in link_statically_labels:
            if owner in static_libs_map:
                fail(owner + " is already linked statically in " +
                     static_libs_map[owner] + " but not exported")

            if owner in direct_exports:
                static_linker_inputs.append(_wrap_static_library_with_alwayslink(
                    ctx,
                    feature_configuration,
                    cc_toolchain,
                    linker_input,
                ))
            else:
                can_be_linked_statically = False

                for static_dep_path in ctx.attr.static_deps:
                    target_specified = _is_target_specified(static_dep_path)
                    static_dep_path_label = ctx.label.relative(static_dep_path)
                    owner_label = linker_input.owner
                    if _check_if_target_under_path(linker_input.owner, static_dep_path_label, target_specified):
                        can_be_linked_statically = True
                        break
                if can_be_linked_statically:
                    static_linker_inputs.append(linker_input)
                else:
                    fail("We can't link " +
                         str(owner) + " either statically or dynamically")

    # Every direct dynamic_dep of this rule will be linked dynamically even if we
    # didn't reach a cc_library exported by one of these dynamic_deps. In other
    # words, the shared library might link more shared libraries than we need
    # in the cc_library graph.
    for dep in ctx.attr.dynamic_deps:
        has_a_used_export = False
        for export in dep[CcSharedLibraryInfo].exports:
            if export in link_dynamically_labels:
                has_a_used_export = True
                break
        if not has_a_used_export:
            dynamic_linker_inputs.append(dep[CcSharedLibraryInfo].linker_input)

    return (static_linker_inputs, dynamic_linker_inputs)

def _same_package_or_above(label_a, label_b):
    if label_a.workspace_name != label_b.workspace_name:
        return False
    package_a_tokenized = label_a.package.split("/")
    package_b_tokenized = label_b.package.split("/")
    if len(package_b_tokenized) < len(package_a_tokenized):
        return False
    for i in range(len(package_a_tokenized)):
        if package_a_tokenized[i] != package_b_tokenized[i]:
            return False
    return True

def _cc_shared_library_impl(ctx):
    cc_toolchain = find_cc_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )

    merged_cc_shared_library_info = _merge_cc_shared_library_infos(ctx)
    exports_map = _build_exports_map_from_only_dynamic_deps(merged_cc_shared_library_info)
    for export in ctx.attr.exports:
        if str(export.label) in exports_map:
            fail("Trying to export a library already exported by a different shared library: " +
                 str(export.label))

        if not _same_package_or_above(ctx.label, export[GraphNodeInfo].label):
            fail(str(export.label) + " cannot be exported from " + str(ctx.label) +
                 " because " + str(export.label) + " is not in the same package " +
                 " or a sub-package")

    preloaded_deps_direct_labels = {}
    preloaded_dep_merged_cc_info = None
    if len(ctx.attr.preloaded_deps) != 0:
        preloaded_deps_cc_infos = []
        for preloaded_dep in ctx.attr.preloaded_deps:
            preloaded_deps_direct_labels[str(preloaded_dep.label)] = True
            preloaded_deps_cc_infos.append(preloaded_dep[CcInfo])

        preloaded_dep_merged_cc_info = cc_common.merge_cc_infos(cc_infos = preloaded_deps_cc_infos)

    static_libs_map = _build_static_libs_map(merged_cc_shared_library_info)
    (static_linker_inputs, dynamic_linker_inputs) = _filter_inputs(
        ctx,
        feature_configuration,
        cc_toolchain,
        exports_map,
        preloaded_deps_direct_labels,
        static_libs_map,
    )

    linking_context = _create_linker_context(ctx, static_linker_inputs, dynamic_linker_inputs)

    # TODO(plf): Decide whether ctx.attr.user_link_flags should come before or after options
    # added by the rule logic.
    user_link_flags = []
    additional_inputs = []
    if ctx.file.visibility_file != None:
        user_link_flags.append(
            "-Wl,--version-script=" + ctx.file.visibility_file.path,
        )
        additional_inputs = [ctx.file.visibility_file]

    user_link_flags.extend(ctx.attr.user_link_flags)

    linking_outputs = cc_common.link(
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        linking_contexts = [linking_context],
        user_link_flags = user_link_flags,
        additional_inputs = additional_inputs,
        name = ctx.label.name,
        output_type = "dynamic_library",
    )

    runfiles = ctx.runfiles(
        files = [linking_outputs.library_to_link.resolved_symlink_dynamic_library],
    )
    for dep in ctx.attr.dynamic_deps:
        runfiles = runfiles.merge(dep[DefaultInfo].data_runfiles)

    exports = []
    for export in ctx.attr.exports:
        exports.append(str(export.label))

    static_libs = []
    for static_linker_input in static_linker_inputs:
        static_libs.append(str(static_linker_input.owner))

    return [
        DefaultInfo(
            files = depset([linking_outputs.library_to_link.resolved_symlink_dynamic_library]),
            runfiles = runfiles,
        ),
        CcSharedLibraryInfo(
            dynamic_deps = merged_cc_shared_library_info,
            exports = exports,
            static_libs = static_libs,
            linker_input = cc_common.create_linker_input(
                owner = ctx.label,
                libraries = depset([linking_outputs.library_to_link]),
            ),
            preloaded_deps = preloaded_dep_merged_cc_info,
        ),
    ]

def _graph_structure_aspect_impl(target, ctx):
    children = []

    if hasattr(ctx.rule.attr, "deps"):
        for dep in ctx.rule.attr.deps:
            if GraphNodeInfo in dep:
                children.append(dep[GraphNodeInfo])

    return [GraphNodeInfo(
        label = ctx.label,
        children = children,
    )]

graph_structure_aspect = aspect(
    attr_aspects = ["*"],
    implementation = _graph_structure_aspect_impl,
)

cc_shared_library = rule(
    implementation = _cc_shared_library_impl,
    attrs = {
        "dynamic_deps": attr.label_list(providers = [CcSharedLibraryInfo]),
        "exports": attr.label_list(providers = [CcInfo], aspects = [graph_structure_aspect]),
        "preloaded_deps": attr.label_list(providers = [CcInfo]),
        "static_deps": attr.string_list(),
        "user_link_flags": attr.string_list(),
        "visibility_file": attr.label(allow_single_file = True),
        "_cc_toolchain": attr.label(default = "@bazel_tools//tools/cpp:current_cc_toolchain"),
    },
    toolchains = ["@rules_cc//cc:toolchain_type"],  # copybara-use-repo-external-label
    fragments = ["cpp"],
)
