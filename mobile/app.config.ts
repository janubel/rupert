import type { ExpoConfig } from 'expo/config';
const config: ExpoConfig = {
  name: 'Rupert Employee', slug: 'rupert-employee', version: '1.0.0', orientation: 'portrait',
  icon: './assets/icon.png', userInterfaceStyle: 'light',
  ios: { bundleIdentifier: process.env.RUPERT_IOS_BUNDLE_ID || 'org.stoverparc.rupert.employee', supportsTablet: true, infoPlist: { ITSAppUsesNonExemptEncryption: false } },
  android: { package: process.env.RUPERT_ANDROID_PACKAGE || 'org.stoverparc.rupert.employee', adaptiveIcon: { foregroundImage: './assets/icon.png', backgroundColor: '#526145' } },
  plugins: ['expo-secure-store'],
  ...(process.env.EXPO_OWNER ? { owner: process.env.EXPO_OWNER } : {}),
  ...(process.env.EAS_PROJECT_ID ? { extra: { eas: { projectId: process.env.EAS_PROJECT_ID } } } : {})
};
export default config;
