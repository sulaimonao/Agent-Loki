interface CommandLike {
  name?: string;
  options?: CommandOptionLike[];
}

interface CommandOptionLike {
  name?: string;
  required?: boolean;
  options?: CommandOptionLike[];
}

const describeOptionOrder = (options: CommandOptionLike[]): string => {
  return options
    .map((option) => `${option.name ?? "<unnamed>"}:${option.required === true ? "required" : "optional"}`)
    .join(", ");
};

const validateOptionList = (
  options: CommandOptionLike[] | undefined,
  path: string,
  errors: string[],
): void => {
  if (!options || options.length === 0) {
    return;
  }

  let seenOptional = false;
  const orderDescription = describeOptionOrder(options);

  for (const option of options) {
    const isRequired = option.required === true;

    if (!isRequired) {
      seenOptional = true;
      continue;
    }

    if (seenOptional) {
      errors.push(
        `${path}: required option \"${option.name ?? "<unnamed>"}\" appears after optional options. Order: ${orderDescription}`,
      );
      break;
    }
  }

  for (const option of options) {
    if (option.options && option.options.length > 0) {
      validateOptionList(option.options, `${path} > ${option.name ?? "<unnamed>"}`, errors);
    }
  }
};

export const validateRequiredOptionsBeforeOptional = (
  commandJson: CommandLike | CommandLike[],
): string[] => {
  const commands = Array.isArray(commandJson) ? commandJson : [commandJson];
  const errors: string[] = [];

  for (const command of commands) {
    validateOptionList(command.options, `/${command.name ?? "<unknown-command>"}`, errors);
  }

  return errors;
};
