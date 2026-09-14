# frozen_string_literal: true

require "json"
require "open3"
require "stringio"
require "tempfile"

# Outside-in CLI specs: every example runs exe/deckard as a real subprocess
# against the plain-Ruby models in spec/fixtures/cli_models.rb.
RSpec.describe "deckard CLI" do
  def run_deckard(*args, stdin: "", env: {})
    root = File.expand_path("../..", __dir__)
    Open3.capture3(env, RbConfig.ruby, "-Ilib", "exe/deckard", *args,
      stdin_data: stdin.dup.force_encoding(Encoding::BINARY), chdir: root)
  end

  def fixture
    File.expand_path("../fixtures/cli_models.rb", __dir__)
  end

  it "dumps an expression: only the stream on stdout, status on stderr" do
    out, err, status = run_deckard("-r", fixture, "-d", "WIDGETS")

    expect(status.exitstatus).to eq(0)
    io = StringIO.new(out)
    expect(Marshal.load(io)).to eq(Deckard::STREAM_HEADER)
    expect(Marshal.load(io)).to eq(["CliWidget", 1, {"name" => "flux"}])
    expect(Marshal.load(io)).to eq(["CliWidget", 2, {"name" => "capacitor"}])
    expect(Marshal.load(io)).to eq(Deckard::STREAM_END)
    expect(io.eof?).to be(true)
    expect(err).to include("dumped 2 total objects")
    expect(err).to include("CliWidget")
  end

  it "loads a dumped stream from stdin" do
    dumped, _, _ = run_deckard("-r", fixture, "-d", "WIDGETS")

    Tempfile.create("deckard-cli-out") do |out_file|
      _, err, status = run_deckard("-r", fixture, "-l",
        stdin: dumped, env: {"DECKARD_CLI_OUT" => out_file.path})

      expect(status.exitstatus).to eq(0)
      loaded = out_file.read.lines.map { |line| JSON.parse(line) }
      expect(loaded.map { |record| record["attributes"]["name"] }).to eq(%w[flux capacitor])
      expect(err).to include("loaded 2 total objects")
    end
  end

  it "runs a dump script file, deduplicating repeated dumps" do
    Tempfile.create(["dump_script", ".rb"]) do |script|
      script.write("dump WIDGETS.first\ndump WIDGETS\n")
      script.flush

      _, err, status = run_deckard("-r", fixture, "-d", script.path)

      expect(status.exitstatus).to eq(0)
      expect(err).to include("dumped 2 total objects")
    end
  end

  it "keeps the stream clean when the application logs to stdout during boot" do
    out, err, status = run_deckard("-r", fixture, "-d", "WIDGETS", env: {"DECKARD_BOOT_LOG" => "1"})

    expect(status.exitstatus).to eq(0)
    expect(err).to include("application booted")
    expect(err).to include("dumped 2 total objects")
    io = StringIO.new(out)
    expect(Marshal.load(io)).to eq(Deckard::STREAM_HEADER)
    expect(Marshal.load(io)).to eq(["CliWidget", 1, {"name" => "flux"}])
    expect(Marshal.load(io)).to eq(["CliWidget", 2, {"name" => "capacitor"}])
    expect(Marshal.load(io)).to eq(Deckard::STREAM_END)
    expect(io.eof?).to be(true)
  end

  it "refuses to load into a production environment unless forced" do
    dumped, _, _ = run_deckard("-r", fixture, "-d", "WIDGETS")

    Tempfile.create("deckard-cli-out") do |out_file|
      env = {"DECKARD_CLI_OUT" => out_file.path, "RAILS_ENV" => "production"}
      _, err, status = run_deckard("-r", fixture, "-l", stdin: dumped, env: env)

      expect(status.exitstatus).to eq(1)
      expect(err).to include("refusing to load into a production environment")
      expect(out_file.read).to be_empty

      _, err, status = run_deckard("-r", fixture, "-l", "--force", stdin: dumped, env: env)

      expect(status.exitstatus).to eq(0)
      expect(err).to include("loaded 2 total objects")
    end
  end

  it "requires exactly one of -d or -l" do
    _, neither_err, neither = run_deckard("-r", fixture)
    _, both_err, both = run_deckard("-r", fixture, "-d", "WIDGETS", "-l")

    expect(neither.exitstatus).not_to eq(0)
    expect(neither_err).to include("exactly one of -d or -l")
    expect(both.exitstatus).not_to eq(0)
    expect(both_err).to include("exactly one of -d or -l")
  end

  it "prints its version" do
    out, _, status = run_deckard("--version")

    expect(status.exitstatus).to eq(0)
    expect(out).to include("deckard #{Deckard::VERSION}")
  end

  it "exits nonzero with a message when the output pipe closes mid-stream" do
    root = File.expand_path("../..", __dir__)
    pipeline = "#{RbConfig.ruby} -Ilib exe/deckard -r #{fixture} -d BIG_WIDGETS | head -c 1 > /dev/null; " \
      "echo \"deckard_exit:${PIPESTATUS[0]}\" >&2"

    _, err, _ = Open3.capture3("bash", "-c", pipeline, chdir: root)

    expect(err).to include("deckard: output pipe closed before the stream completed")
    expect(err).to include("deckard_exit:1")
  end

  it "exits nonzero with the error on a truncated stream" do
    truncated = StringIO.new
    Marshal.dump(Deckard::STREAM_HEADER, truncated)
    Marshal.dump(["CliWidget", 1, {"name" => "cut off"}], truncated)

    Tempfile.create("deckard-cli-out") do |out_file|
      _, err, status = run_deckard("-r", fixture, "-l",
        stdin: truncated.string, env: {"DECKARD_CLI_OUT" => out_file.path})

      expect(status.exitstatus).to eq(1)
      expect(err).to include("Deckard::InvalidStream")
    end
  end
end
