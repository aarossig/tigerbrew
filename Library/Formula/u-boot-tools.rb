class UBootTools < Formula
  desc "Universal boot loader"
  homepage "http://www.denx.de/wiki/U-Boot/"
  url "ftp://ftp.denx.de/pub/u-boot/u-boot-2015.01.tar.bz2"
  sha1 "8d22ab0d9f3902122f160280facacc468bad0da9"

  bottle do
    cellar :any
    sha1 "cc0677b54979ae9ae04a0bae5c7124c05e269a97" => :yosemite
    sha1 "081589c5dadc378d31accd101be6486023de7fe2" => :mavericks
    sha1 "0acb015f103446d432d69db39b0a14b0abb9b130" => :mountain_lion
  end

  depends_on "openssl"

  def install
    system "make", "sandbox_defconfig"
    system "make", "tools"
    bin.install "tools/mkimage"
    man1.install "doc/mkimage.1"
  end

  test do
    system bin/"mkimage", "-V"
  end
end
