export default async () => {
  const clientConfigs = (await import(`./${process.env.NODE_ENV}.js`)).default;
  return clientConfigs;
};
