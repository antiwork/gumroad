import { getVideoDimensionsFromFile, checkVideoHasAudio } from "$app/utils/image";

// Mock File and URL.createObjectURL
const mockFile = new File([''], 'test.webm', { type: 'video/webm' });
const mockUrl = 'blob:mock-url';

// Mock URL.createObjectURL and URL.revokeObjectURL
global.URL.createObjectURL = jest.fn(() => mockUrl);
global.URL.revokeObjectURL = jest.fn();

// Mock document.createElement
const mockVideo = {
  preload: '',
  onloadedmetadata: null as (() => void) | null,
  onerror: null as ((error: any) => void) | null,
  src: '',
  videoWidth: 1920,
  videoHeight: 1080,
  audioTracks: {
    length: 0
  }
};

document.createElement = jest.fn((tagName: string) => {
  if (tagName === 'video') {
    return mockVideo as any;
  }
  return document.createElement(tagName);
});

describe('Image Utils', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    mockVideo.onloadedmetadata = null;
    mockVideo.onerror = null;
    mockVideo.audioTracks.length = 0;
  });

  describe('getVideoDimensionsFromFile', () => {
    it('should return video dimensions when metadata loads successfully', async () => {
      const promise = getVideoDimensionsFromFile(mockFile);

      // Simulate successful metadata load
      setTimeout(() => {
        if (mockVideo.onloadedmetadata) {
          mockVideo.onloadedmetadata();
        }
      }, 0);

      const result = await promise;

      expect(URL.createObjectURL).toHaveBeenCalledWith(mockFile);
      expect(mockVideo.preload).toBe('metadata');
      expect(mockVideo.src).toBe(mockUrl);
      expect(URL.revokeObjectURL).toHaveBeenCalledWith(mockUrl);
      expect(result).toEqual({ width: 1920, height: 1080 });
    });

    it('should reject when video fails to load', async () => {
      const promise = getVideoDimensionsFromFile(mockFile);

      // Simulate error
      setTimeout(() => {
        if (mockVideo.onerror) {
          mockVideo.onerror(new Error('Video load failed'));
        }
      }, 0);

      await expect(promise).rejects.toThrow('Video load failed');
      expect(URL.revokeObjectURL).toHaveBeenCalledWith(mockUrl);
    });
  });

  describe('checkVideoHasAudio', () => {
    it('should return false when video has no audio tracks', async () => {
      mockVideo.audioTracks.length = 0;

      const promise = checkVideoHasAudio(mockFile);

      // Simulate successful metadata load
      setTimeout(() => {
        if (mockVideo.onloadedmetadata) {
          mockVideo.onloadedmetadata();
        }
      }, 0);

      const result = await promise;

      expect(URL.createObjectURL).toHaveBeenCalledWith(mockFile);
      expect(mockVideo.preload).toBe('metadata');
      expect(mockVideo.src).toBe(mockUrl);
      expect(URL.revokeObjectURL).toHaveBeenCalledWith(mockUrl);
      expect(result).toBe(false);
    });

    it('should return true when video has audio tracks', async () => {
      mockVideo.audioTracks.length = 1;

      const promise = checkVideoHasAudio(mockFile);

      // Simulate successful metadata load
      setTimeout(() => {
        if (mockVideo.onloadedmetadata) {
          mockVideo.onloadedmetadata();
        }
      }, 0);

      const result = await promise;

      expect(URL.createObjectURL).toHaveBeenCalledWith(mockFile);
      expect(mockVideo.preload).toBe('metadata');
      expect(mockVideo.src).toBe(mockUrl);
      expect(URL.revokeObjectURL).toHaveBeenCalledWith(mockUrl);
      expect(result).toBe(true);
    });

    it('should reject when video fails to load', async () => {
      const promise = checkVideoHasAudio(mockFile);

      // Simulate error
      setTimeout(() => {
        if (mockVideo.onerror) {
          mockVideo.onerror(new Error('Video load failed'));
        }
      }, 0);

      await expect(promise).rejects.toThrow('Video load failed');
      expect(URL.revokeObjectURL).toHaveBeenCalledWith(mockUrl);
    });
  });
});
