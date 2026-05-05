import { cn } from '../lib/utils';

type ClosedmeshWordmarkProps = {
  className?: string;
};

export function ClosedmeshWordmark({ className }: ClosedmeshWordmarkProps) {
  return (
    <span className={cn('whitespace-nowrap', className)}>
      <span className="text-primary">closed</span>
      mesh
    </span>
  );
}

ClosedmeshWordmark.displayName = 'ClosedmeshWordmark';
