class OmlxAgent < Formula
  desc "MLX Isolated Agent Stack CLI"
  homepage "https://github.com/aarogozin/mlx-to-isolated-hermes"
  url "https://github.com/aarogozin/mlx-to-isolated-hermes/archive/refs/tags/v0.5.2.tar.gz"
  # Placeholder SHA — users or CI can update this when tags are pushed
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  depends_on "go" => :build

  def install
    system "go", "build", *std_go_args(output: bin/"omlx-agent"), "."
  end

  test do
    assert_match "MLX Isolated Agent Stack", shell_output("#{bin}/omlx-agent")
  end
end
