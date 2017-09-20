"""An action to run Dart codegen.

This action should only be used internally. Authors of codegen builders should
use dart_codegen_rule to create a unique skylark rule for their builder. Clients
of codegen builders should use the rules provided by authors.
"""

load(
    "//dart/build_rules/internal:common.bzl",
    "label_to_dart_package_name",
    "make_dart_context",
)
load(
    "//dart/build_rules/common:constants.bzl",
    "codegen_outline_extension",
)

def _tmp_file(ctx, file_suffix, lines):
  """Creates a file named after the ctx label containing lines.

  Args:
    ctx: The skylark rule context.
    file_suffix: The suffix to append to the ctx label for the file name.
    lines: A list of strings to be joined by newlines as the file content.

  Returns:
    The File which was created.

    See [File documentation](https://goo.gl/fYvlcT) for more information.
  """
  tmp_file = ctx.new_file(ctx.configuration.bin_dir,
                          "%s_%s" % (ctx.label.name, file_suffix))
  ctx.file_action(output=tmp_file, content="\n".join(lines))
  return tmp_file

def _input_path(file):
  return file.short_path.replace("../", "external/", 1)

def _inputs_tmp_file(ctx, file_sequence, file_suffix):
  """Creates a file containing path information for files in file_sequence.

  Args:
    ctx: The skylark rule context
    file_sequence: A sequence of File objects.
    file_suffix: The suffix to use when naming the temporary file. The file will
        be prefixed with the build label name and an underscore.

  Returns:
    A File with the paths of each file in file_sequence.
  """
  paths = [_input_path(f) for f in file_sequence]
  return _tmp_file(ctx, file_suffix, paths)

def _package_map_tmp_file(ctx, dart_context, file_suffix = None):
  """Creates a file containing the path under bazel to each Dart dependency.

  Args:
    ctx: The skylark rule context.
    dart_context: The Dart build context.
    file_suffix: The suffix to append to the ctx label for the file name.

  Returns:
    A File with the package name and path for each transitive dep in the format
    <package name>:<path under bazel root>
  """
  labels = [dep.label for dep in dart_context.transitive_deps.values()]
  labels += [ctx.label]
  package_paths = ["%s:%s" % (label_to_dart_package_name(label), label.package)
                   for label in labels]
  return _tmp_file(
      ctx,
      "packages%s" % (("_%s" % file_suffix) if file_suffix else ""),
      package_paths)

def _declare_outs(ctx, generate_for, in_extension, out_extensions):
  """Declares the outs for a generator.

  This declares one outfile per entry in out_extensions for each file in
  generate_for which ends with in_extension.

  Example:

    generate_for = ["a.dart", "b.css"]
    in_extension = ".dart"
    out_extensions = [".g.dart", ".info.xml"]

    # If outline_only == False
    outs => ["a.g.dart", "a.info.xml"]
    # If outline_only == True
    outs => ["a.outline.g.dart", "a.outline.info.xml"]


  Args:
    ctx: The context.
    generate_for: The files to treat as primary inputs for codegen.
    in_extension: The file extension to process.
    out_extensions: One or more output extensions that should be emitted.

  Returns:
    A sequence of File objects which will be emitted.
  """
  if not out_extensions:
    fail("must not be empty", attr="out_extensions")

  outs = []
  for src in generate_for:
    if (src.basename.endswith(in_extension)):
      for ext in out_extensions:
        out_name = "%s%s" % (src.basename[:-1 * len(in_extension)], ext)
        output = ctx.new_file(src, out_name)
        outs.append(output)
  return outs

def _collect_summaries(deps):
  """Collects all summaries for deps, fails if any summaries are missing.

  Args:
    deps: The deps to collect summaries for. Transitive summaries are not
      included.

  Returns:
    The list of strong summary files.
  """
  missing_summaries = [
      dep for dep in deps
      if dep.dart.strong_summary == None and dep.dart.dart_srcs
  ]
  if missing_summaries:
    fail("Missing some strong summaries: %s"
         % [dep.label for dep in missing_summaries])

  return [
      dep.dart.strong_summary for dep in deps
      if dep.dart.strong_summary and dep.dart.dart_srcs
  ]

def codegen_action(
    ctx,
    srcs,
    in_extension,
    out_extensions,
    generator_binary,
    forced_deps=None,
    generator_args=None,
    arg_prefix=None,
    input_provider=None,
    log_level="warning",
    generate_for=None,
    use_summaries=True,
    outline_only=False,
    outline_summary_deps=[],):
  """Runs a dart codegen action.

  Args:
    ctx: The skylark context.
    srcs: The srcs for this action.
    in_extension: The file extension to process.
    out_extensions: One or more output extensions that should be emitted.
    generator_binary: The binary to invoke which will perform codegen.
    forced_deps: Extra deps which will always be provided to this action.
    generator_args: Extra arguments to pass on to the code generator.
    arg_prefix: Prefix to match for --define=%arg_prefix%_CODEGEN_ARGS=%value%
      flags. Any matching args will be passed on to the generator.
    input_provider: Optional provider to read for inputs instead of using the
      default logic. Generally this will be coming from a codegen_aspect that
      collects inputs.
    log_level: The minimum level at which to log to the console.
    generate_for: The files to treat as primary inputs for codegen.
    use_summaries: Whether or not to to use analyzer summaries for this action.
    outline_only: Whether or not we are declaring outline file outputs.
    outline_summary_deps: If outline_only == True, the deps to provide summaries
      for. No other summaries will be available.

  Returns:
    The set of File objects which will be emitted.
  """
  if not generate_for:
    generate_for = srcs

  out_base = ctx.configuration.bin_dir

  real_out_extensions = out_extensions if not outline_only else [
      ".%s%s" % (codegen_outline_extension, ext) for ext in out_extensions]

  outs = _declare_outs(
      ctx, generate_for, in_extension, out_extensions, real_outline_only)
  if not outs:
    return depset()

  log_path = "%s/%s/%s%s.log" % (
      out_base.path, ctx.label.package, ctx.label.name,
      (".%s" % codegen_outline_extension) if outline_only else "")

  dart_deps = [dep for dep in ctx.attr.deps if hasattr(dep, "dart")]
  dart_context = make_dart_context(ctx, deps = dart_deps)

  optional_prefix = ("%s_" % codegen_outline_extension) if outline_only else ""
  package_map = _package_map_tmp_file(
      ctx, dart_context, optional_prefix)
  inputs_file = _inputs_tmp_file(
      ctx, generate_for, "%sinputs_file" % optional_prefix)

  # Extra inputs required for the main action.
  extra_inputs = [inputs_file, package_map]

  arguments = [
      # The directories where blaze may place files. These directories could
      # correspond to the workspace root when searching for a file.
      "--root-dir=.",
      "--root-dir=%s" % ctx.configuration.genfiles_dir.path,
      "--root-dir=%s" % ctx.configuration.bin_dir.path,

      "--package-path=%s" % ctx.label.package,
      "--out=%s" % out_base.path,
      "--log=%s" % log_path,
      "--in-extension=%s" % in_extension,
      # TODO(nbosch) rename this to 'input' or 'generate-for'
      "--srcs-file=%s" % inputs_file.path,
      "--package-map=%s" % package_map.path,
      "--log-level=%s" % log_level,
  ]
  arguments += ["--out-extension=%s" % ext for ext in real_out_extensions]

  if not use_summaries:
    arguments += ["--no-use-summaries"]
  # Prevent the source_gen ArgParser from interpreting generator args.
  arguments += ["--"]

  filtered_deps = depset()
  if not outline_only:
    if input_provider:
      for dep in ctx.attr.deps:
        if hasattr(dep, "dart_codegen"):
          dep_srcs = dep.dart_codegen.srcs.get(input_provider)
          if dep_srcs:
            filtered_deps += dep_srcs
    elif not use_summaries:
      filtered_deps += ctx.files.deps

  filtered_deps += forced_deps

  if use_summaries:
    if outline_only:
      summaries = depset(_collect_summaries(outline_summary_deps))
      for dep in outline_summary_deps:
        summaries += _collect_summaries(dep.dart.transitive_deps.values())
    else:
      summaries = _collect_summaries(dart_context.transitive_deps.values())
    arguments += ["--summary-files=%s" % summary.path for summary in summaries]
    sdk_summary = [f for f in ctx.files._sdk if f.path.endswith("strong.sum")][0]
    arguments += ["--dart-sdk-summary=%s" % sdk_summary.path]

    # Files that have a relative import need to be reachable via an 'asset:' uri
    local_deps = [dep for dep in dart_context.transitive_deps.values()
                  if dep.dart.package  == dart_context.package]
    non_lib_srcs = [src for dep in local_deps for src in dep.dart.srcs
                    if not src.short_path.startswith(dep.dart.lib_root)
                    and src.short_path.startswith(ctx.label.package)]
    srcs = srcs + non_lib_srcs

    all_srcs = depset([])
    all_srcs += srcs
    all_srcs += generate_for
    srcs_file = _inputs_tmp_file(
        ctx, all_srcs, "%ssrcs_file" % optional_prefix)
    extra_inputs.append(srcs_file)
    arguments += [
        "--srcs-file=%s" % srcs_file.path,
        "--package-path=%s" % ctx.label.package,
        "--",
    ]

  arguments += generator_args
  if outline_only:
    arguments += ["--outline-only"]
  if arg_prefix:
    codegen_arg_key = "%s_CODEGEN_ARGS" % arg_prefix
    if codegen_arg_key in ctx.var:
      define_args = ctx.var[codegen_arg_key]
      if define_args:
        arguments += ["--%s" % arg for arg in define_args.split(",")]

  # Bazel requires worker args in a separate file
  args_file = _tmp_file(
      ctx, "%sargs" % optional_prefix, arguments)
  extra_inputs.append(args_file)

  if "DART_CODEGEN_ASYNC_STACK_TRACE" in ctx.var:
    arguments = ["--async-stack-trace"]
  else:
    arguments = []

  arguments += ["@%s" % args_file.path]

  inputs = depset()
  inputs += srcs
  inputs += generate_for
  inputs += filtered_deps
  inputs += extra_inputs
  if use_summaries:
    inputs += summaries
    inputs += [sdk_summary]

  ctx.action(inputs=list(inputs),
             outputs=outs,
             executable=generator_binary,
             progress_message="Generating %s files %s " % (
                 ", ".join(real_out_extensions), ctx.label),
             mnemonic="DartSourceGen",
             execution_requirements={"supports-workers": "1"},
             arguments=arguments)

  return depset(outs)
