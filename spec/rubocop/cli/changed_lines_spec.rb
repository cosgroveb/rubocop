# frozen_string_literal: true

RSpec.describe 'RuboCop::CLI --changed-lines', :isolated_environment do # rubocop:disable RSpec/DescribeClass
  subject(:cli) { RuboCop::CLI.new }

  include_context 'cli spec behavior'

  def git(*args)
    _stdout, stderr, status = Open3.capture3('git', *args)

    raise "git #{args.join(' ')} failed: #{stderr}" unless status.success?
  end

  def git_init
    git('init')
    # `git commit` may spawn a detached background maintenance process whose own lock file removal
    # races with the temporary directory cleanup and makes it raise `Errno::ENOENT`.
    git('config', 'maintenance.auto', 'false')
    git('config', 'gc.auto', '0')
  end

  def commit_all(message)
    git('add', '-A')
    git('-c', 'user.email=test@example.com', '-c', 'user.name=Test', 'commit', '-m', message)
  end

  def reported
    JSON.parse($stdout.string)['files'].flat_map do |file|
      file['offenses'].map do |offense|
        "#{File.basename(file['path'])}:#{offense['location']['start_line']} #{offense['cop_name']}"
      end
    end
  end

  before do
    git_init
    create_file('.rubocop.yml', <<~YAML)
      AllCops:
        NewCops: disable
        SuggestExtensions: false
    YAML
    create_file('legacy.rb', <<~RUBY)
      # frozen_string_literal: true

      puts "one"
      puts "two"
      puts "three"
    RUBY
    commit_all('init')
  end

  it 'reports only the offenses on lines that changed' do
    create_file('legacy.rb', <<~RUBY)
      # frozen_string_literal: true

      puts "one"
      puts "TWO"
      puts "three"
    RUBY

    expect(cli.run(['--changed-lines', '--format', 'json'])).to eq(1)
    expect(reported).to eq(['legacy.rb:4 Style/StringLiterals'])
  end

  it 'passes when the only offenses are on lines that did not change' do
    create_file('legacy.rb', <<~RUBY)
      # frozen_string_literal: true

      puts "one"
      puts "two"
      puts "three"
      puts 'four'
    RUBY

    expect(cli.run(['--changed-lines', '--format', 'json'])).to eq(0)
    expect(reported).to be_empty
  end

  it 'reports an offense that starts above the change but reaches into it' do
    create_file('ternary.rb', <<~RUBY)
      # frozen_string_literal: true

      value = rand.positive? ?
        :yes :
        :no
      puts value
    RUBY
    commit_all('ternary')
    create_file('ternary.rb', <<~RUBY)
      # frozen_string_literal: true

      value = rand.positive? ?
        :yes :
        :nope
      puts value
    RUBY

    arguments = ['--changed-lines', '--format', 'json', '--only', 'Style/MultilineTernaryOperator']

    expect(cli.run(arguments)).to eq(1)
    expect(reported).to eq(['ternary.rb:3 Style/MultilineTernaryOperator'])
  end

  it 'reports every offense in an untracked file' do
    create_file('new.rb', <<~RUBY)
      # frozen_string_literal: true

      puts "one"
      puts "two"
    RUBY

    expect(cli.run(['--changed-lines', '--format', 'json'])).to eq(1)
    expect(reported).to eq(['new.rb:3 Style/StringLiterals', 'new.rb:4 Style/StringLiterals'])
  end

  it 'reports a syntax error on a line that did not change' do
    create_file('method.rb', <<~RUBY)
      # frozen_string_literal: true

      def method
        puts 'body'
      end
    RUBY
    commit_all('method')
    create_file('method.rb', <<~RUBY)
      # frozen_string_literal: true

      def method
        puts 'body'
    RUBY

    expect(cli.run(['--changed-lines', '--format', 'json'])).to eq(1)
    expect(reported).to eq(['method.rb:4 Lint/Syntax'])
  end

  it 'compares against the revision given to --changed' do
    create_file('legacy.rb', <<~RUBY)
      # frozen_string_literal: true

      puts "one"
      puts "two"
      puts "THREE"
    RUBY
    commit_all('second')

    expect(cli.run(['--changed=HEAD~1', '--changed-lines', '--format', 'json'])).to eq(1)
    expect(reported).to eq(['legacy.rb:5 Style/StringLiterals'])
  end

  it 'cannot be combined with autocorrection' do
    expect(cli.run(['--changed-lines', '--autocorrect'])).to eq(2)
    expect($stderr.string).to include('--changed-lines cannot be used with autocorrection.')
  end

  it 'cannot be combined with --stdin' do
    expect(cli.run(['--changed-lines', '--stdin', 'example.rb'])).to eq(2)
    expect($stderr.string).to include('--changed cannot be used with --stdin.')
  end
end
