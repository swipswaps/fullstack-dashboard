import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig(({ mode }) => {
  // Use repository name as base for GitHub Pages
  // Set to '/' for local development
  const base = mode === 'production' ? '/fullstack-dashboard/' : '/'

  return {
    base,
    plugins: [react()],
    server: {
      proxy: {
        '/api': {
          target: 'http://localhost:3001',
          changeOrigin: true,
        }
      }
    }
  }
})
