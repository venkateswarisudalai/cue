import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.tsx'
import { decodeShare, isShareHash } from './core/share'
import { initAnalytics } from './services/analytics'
import { SharedNoteView } from './ui'

const root = createRoot(document.getElementById('root')!)

if (isShareHash(location.hash)) {
  // A shared note: shown read-only, and not counted (the page would carry the meeting's details).
  void decodeShare(location.hash).then((note) => root.render(<StrictMode><SharedNoteView note={note} /></StrictMode>))
} else {
  initAnalytics()
  root.render(
    <StrictMode>
      <App />
    </StrictMode>,
  )
}
