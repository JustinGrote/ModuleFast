// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// https://astro.build/config
const repo = process.env.GITHUB_REPOSITORY;
const site = repo ? `https://${repo.split('/')[0]}.github.io` : undefined;
const base = repo ? `/${repo.split('/')[1]}/` : undefined;

export default defineConfig({
	site,
	base,
	integrations: [
		starlight({
			title: 'ModuleFast',
			social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/JustinGrote/ModuleFast' }],
			sidebar: [
				{
					label: 'Guides',
					items: [{ autogenerate: { directory: 'guides' } }],
				},
				{
					label: 'Reference',
					items: [{ autogenerate: { directory: 'reference' } }],
				},
			],
		}),
	],
});
