class Helixcli < Formula
  desc "Native macOS CLI for Line 6 HX Stomp control"
  homepage "https://github.com/acwilan/helixcli"
  url "https://github.com/acwilan/helixcli/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "PLACEHOLDER_SHA256"
  license "MIT"

  depends_on xcode: ["15.0", :build]
  depends_on macos: :sonoma

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release"
    bin.install ".build/release/helixcli"
    
    # Generate completions
    generate_completions_from_executable(bin/"helixcli", "--generate-completion")
  end

  test do
    # Test that the binary exists and returns version
    assert_match version.to_s, shell_output("#{bin}/helixcli --version")
    
    # Test JSON output format
    output = shell_output("#{bin}/helixcli preset list")
    assert_match "\"success\": true", output
  end
end
