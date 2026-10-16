# frozen_string_literal: true

require 'open3'

module RuboCop
  # Lists the files that differ from a git revision, for `--changed`.
  #
  # Shelling out to `git` keeps RuboCop free of a version control dependency,
  # and means the answer is exactly what git would give on the command line.
  #
  # @api private
  class ChangedFiles
    DEFAULT_REVISION = 'HEAD'
    FILESYSTEM_ENCODING = Encoding.find('filesystem')
    EVERY_LINE = (1..).freeze
    HUNK_HEADER = /\A@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@/.freeze
    private_constant :EVERY_LINE, :HUNK_HEADER

    # Whether git can resolve `name` to a commit in the current repository.
    def self.revision?(name)
      _stdout, _stderr, status =
        Open3.capture3('git', 'rev-parse', '--verify', '--quiet', "#{name}^{commit}")
      status.success?
    rescue Errno::ENOENT
      false
    end

    # The offenses that reach into any of a file's changed lines, as {#lines}
    # gives them. An offense spanning several lines counts when any of them
    # changed. A syntax error is kept wherever it lands, since deleting one
    # line can break the parse of lines nobody touched.
    def self.touching(ranges, offenses)
      offenses.select do |offense|
        offense.cop_name == 'Lint/Syntax' ||
          ranges.any? do |range|
            range.cover?(offense.line) || range.begin.between?(offense.line, offense.last_line)
          end
      end
    end

    def initialize(revision = nil)
      @revision = revision || DEFAULT_REVISION
    end

    # Files that were added or modified since the revision, as absolute paths.
    # Deleted files are left out - there is nothing left to inspect - and
    # untracked files are included, since a file that is new to the working
    # tree has changed as surely as one git already knows about.
    #
    # @return [Set<String>]
    def paths
      root = repository_root

      (modified_paths + untracked_paths).to_set { |path| File.expand_path(path, root) }
    end

    # @return [Array<String>] the files among these that changed
    def filter(files)
      changed = paths
      files.select { |file| changed.include?(file) }
    end

    # The lines added or modified since the revision, keyed by the same paths
    # as {#paths}. A file that only lost lines, or was only renamed, has no
    # lines left to point at. Every line of an untracked file is new.
    #
    # @return [Hash{String => Array<Range>}]
    def lines
      root = repository_root
      changed = modified_paths.to_h { |path| [path, []] }
      hunk_ranges(changed)
      untracked_paths.each { |path| changed[path] = [EVERY_LINE] }

      changed.transform_keys { |path| File.expand_path(path, root) }
    end

    private

    def repository_root
      filesystem_path(git('rev-parse', '--show-toplevel').b.chomp)
    end

    def modified_paths
      split_paths(diff('--name-only', '--diff-filter=d', '-z'))
    end

    # Fills in the ranges of the files already listed, from a patch without
    # context lines, where each hunk header gives the new lines exactly.
    def hunk_ranges(changed)
      header = false
      ranges = nil

      patch.each_line do |line|
        if line.start_with?('diff --git ')
          header = true
        elsif header && line.start_with?('+++ ')
          ranges = changed[filesystem_path(unquote(header_path(line)))]
        elsif (range = hunk_range(line))
          # An added line reading `++ x` prints as `+++ x`, so file headers
          # only count before the first hunk.
          header = false
          ranges&.push(range) if range.size.positive?
        end
      end
    end

    # The options pin down what git prints whatever the user's diff settings.
    def patch
      diff('--no-color', '--no-ext-diff', '--no-textconv', '--no-prefix',
           '--find-renames', '--diff-filter=d', '--unified=0').b
    end

    # A hunk that only removes lines gives an empty range.
    def hunk_range(line)
      return unless (hunk = HUNK_HEADER.match(line))

      start = hunk[1].to_i
      start..(start + (hunk[2] || 1).to_i - 1)
    end

    # git ends a name that has a space in it with a tab, so `patch` can tell
    # where the name stops.
    def header_path(line)
      line.delete_prefix('+++ ').chomp.delete_suffix("\t")
    end

    # `core.quotePath=false` leaves non-ASCII names alone, but git still
    # C-quotes a name with a quote, backslash, or control character in it.
    def unquote(path)
      path.start_with?('"') ? path.undump : path
    end

    def diff(*args, revision: @revision)
      # `diff.relative` would make git report paths relative to the current
      # directory rather than to the repository root.
      git('-c', 'diff.relative=false', '-c', 'core.quotePath=false', 'diff', *args, revision)
    rescue Error
      raise unless revision == DEFAULT_REVISION && unborn_head?

      # A repository without commits has no `HEAD` to diff against, but files
      # can already be staged in it. Against the empty tree every one of them
      # counts as changed, which is what the caller wants to hear rather than
      # an error about `HEAD` not resolving.
      diff(*args, revision: empty_tree)
    end

    def unborn_head?
      !self.class.revision?(DEFAULT_REVISION)
    end

    # Hashed rather than hardcoded, since its id depends on the repository's
    # object format (SHA-1 or SHA-256).
    def empty_tree
      git('hash-object', '-t', 'tree', '--stdin').chomp
    end

    def untracked_paths
      # Unlike `git diff`, `ls-files` only looks under the current directory, so
      # the `:/` pathspec widens it to the whole repository, and `--full-name`
      # anchors the paths to the repository root the way `git diff` does.
      split_paths(
        git('ls-files', '--others', '--exclude-standard', '--full-name', '-z', '--', ':/')
      )
    end

    # The `-z` above is what makes these usable: without it git wraps any path
    # that is not plain ASCII in quotes and octal escapes, and those files drop
    # out of the comparison without a word.
    def split_paths(output)
      output.b.split("\0").reject(&:empty?).map { |path| filesystem_path(path) }
    end

    # git hands back bytes, which Ruby tags with the encoding the process
    # happens to have been started in - splitting those bytes as US-ASCII raises
    # on any path that is not. They have to end up in the encoding `Dir.glob`
    # uses, or a path with a non-ASCII character in it never matches the file
    # list it is compared against.
    #
    # On POSIX those bytes are already the filesystem's own, so the encoding is
    # simply corrected. Windows is the exception: git converts paths to UTF-8 on
    # the way out, while Ruby reports file names in the local code page, so the
    # two have to be reconciled.
    def filesystem_path(path)
      path = path.dup

      return path.force_encoding(FILESYSTEM_ENCODING) unless Platform.windows?

      path.force_encoding(Encoding::UTF_8).encode(FILESYSTEM_ENCODING)
    rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
      # A name the local code page cannot represent. Nothing good is left to do
      # with it, and dropping it would be worse than reporting it as-is.
      path.force_encoding(FILESYSTEM_ENCODING)
    end

    def git(*args)
      stdout, stderr, status = Open3.capture3('git', *args)

      raise Error, git_error_message(stderr) unless status.success?

      stdout
    rescue Errno::ENOENT
      raise Error, '--changed requires git to be installed and on your PATH.'
    end

    def git_error_message(stderr)
      message = stderr.strip
      message = 'git failed with no output on standard error.' if message.empty?

      "--changed could not ask git which files changed: #{message}"
    end
  end
end
