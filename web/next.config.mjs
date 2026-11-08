// Database drivers stay as normal Node packages (not bundled).
const nextConfig = {
  serverExternalPackages: ['mysql2', 'mongodb', 'redis', 'bcryptjs'],
};
export default nextConfig;
