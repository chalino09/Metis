import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Keep production validation from overwriting the assets used by `next dev`.
  // Running both against `.next` can leave localhost serving stale JavaScript or CSS.
  distDir: process.env.NODE_ENV === "production" ? ".next-build" : ".next",
};

export default nextConfig;
