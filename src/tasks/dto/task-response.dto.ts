import { ApiProperty, ApiPropertyOptional } from '@nestjs/swagger';

export class TaskResponseDto {
  @ApiProperty({ example: 1 })
  id: number;

  @ApiProperty({ example: 'Configurar pipeline de CI' })
  title: string;

  @ApiPropertyOptional({
    example: 'Agregar build y tests en GitHub Actions',
    nullable: true,
    type: String,
  })
  description: string | null;

  @ApiProperty({ example: false })
  completed: boolean;

  @ApiProperty()
  createdAt: Date;

  @ApiProperty()
  updatedAt: Date;
}
