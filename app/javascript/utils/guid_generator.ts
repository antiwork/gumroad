// Reference - https://stackoverflow.com/questions/105034/create-guid-uuid-in-javascript#answer-105074

const GuidGenerator = {
  generate(): string {
    return `${s4() + s4()}-${s4()}-${s4()}-${s4()}-${s4()}${s4()}${s4()}`;
    function s4() {
      return Math.floor((1 + Math.random()) * 0x10000)
        .toString(16)
        .substring(1);
    }
  },
};
export default GuidGenerator;
