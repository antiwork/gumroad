// Only import and initialize Firebase on the client side
let app: any = null;
let auth: any = null;
let googleProvider: any = null;

const initializeFirebase = async () => {
  if (typeof window === 'undefined') return null; // Don't run on server

  const { initializeApp } = await import("firebase/app");
  const { getAuth, GoogleAuthProvider } = await import("firebase/auth");

  // Firebase configuration
  const firebaseConfig = {
    apiKey: "AIzaSyBUnTDSnE7dJlpJ5gdyh7sL-L1xBxvpK04",
    authDomain: "n8n-marketplace.firebaseapp.com",
    projectId: "n8n-marketplace",
    storageBucket: "n8n-marketplace.firebasestorage.app",
    messagingSenderId: "204925551849",
    appId: "1:204925551849:web:8f1958ed07b48ac6391c78",
    measurementId: "G-Y2ZD6B20HP"
  };

  // Initialize Firebase
  app = initializeApp(firebaseConfig);
  auth = getAuth(app);
  googleProvider = new GoogleAuthProvider();

  return { app, auth, googleProvider };
};

export interface FirebaseUserData {
  uid: string;
  email: string;
  displayName: string;
  photoURL: string;
  idToken: string;
}

export const signInWithGoogle = async (): Promise<FirebaseUserData | null> => {
  try {
    // Initialize Firebase if not already done
    if (!auth) {
      await initializeFirebase();
    }

    if (!auth || !googleProvider) {
      throw new Error('Firebase not initialized');
    }

    // Configure Google provider (do this each time to ensure it's available)
    googleProvider.addScope('email');
    googleProvider.addScope('profile');

    const { signInWithPopup } = await import("firebase/auth");
    const result = await signInWithPopup(auth, googleProvider);
    const user = result.user;
    const idToken = await user.getIdToken();

    return {
      uid: user.uid,
      email: user.email || '',
      displayName: user.displayName || '',
      photoURL: user.photoURL || '',
      idToken: idToken
    };
  } catch (error) {
    console.error('Firebase Google sign-in error:', error);
    return null;
  }
};

export const signOutFirebase = async (): Promise<void> => {
  try {
    if (!auth) {
      await initializeFirebase();
    }
    if (auth) {
      await auth.signOut();
    }
  } catch (error) {
    console.error('Firebase sign-out error:', error);
  }
};

export { auth };
