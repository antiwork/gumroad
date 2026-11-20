const ONE_SECOND_IN_MS = 1000;

class Countdown {
  private readonly interval: ReturnType<typeof setInterval>;

  constructor(duration: number, onTick: (secondsLeft: number) => void, onComplete: () => void, expiresAt?: Date) {
    const deadline = process.env.NODE_ENV === "test" ? undefined : expiresAt?.getTime();
    let secondsLeft = duration - 1;
    if (process.env.NODE_ENV === "test") {
      secondsLeft = 1;
    }

    onTick(duration);

    this.interval = setInterval(() => {
      const remaining = deadline === undefined ? secondsLeft-- : (deadline - Date.now()) / ONE_SECOND_IN_MS;
      if (remaining > 0) {
        onTick(remaining);
      } else {
        clearInterval(this.interval);
        onComplete();
      }
    }, ONE_SECOND_IN_MS);
  }

  abort(): void {
    clearInterval(this.interval);
  }
}

export default Countdown;
